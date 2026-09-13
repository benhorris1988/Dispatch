# Coverage audit — Dispatch against requirements v0.1

What this repository actually implements, checked requirement by requirement against
*Dispatch — Requirements and Design v0.1* (`docs/requirements-v0.1.md`, 8 September 2026).

Re-audited 13 September 2026 against the working tree at commit `5fee233`, with the API running on
`http://localhost:8090` and the demo seeded. It supersedes the audit of `dbbec9c`. Every verdict
below comes from reading the code that does the work — and, where the requirement implies a person
does something, from finding the control in `mobile/lib/screens/` that reaches it. An endpoint no
screen calls is recorded as such. Schema columns that nothing reads are recorded as such. The status
column is deliberately unkind.

## 1 Summary

| Scope | Done | Partial | Not done | Not applicable here | Total |
|---|---|---|---|---|---|
| All functional requirements | 72 | 40 | 8 | 7 | 127 |
| R1 (the MVP) | 65 | 15 | 0 | 0 | 80 |
| Must priority | 62 | 19 | 3 | 1 | 85 |
| Must **and** R1 | 62 | 14 | 0 | 0 | 76 |
| Should priority | 9 | 21 | 3 | 5 | 38 |
| Could priority | 1 | 0 | 2 | 1 | 4 |

Non-functional: of the 18 NFRs, two are structurally met, eight are partly met, and eight are
hosting or operations claims that a local implementation cannot make. Section 3 sets them out.
One of them has **regressed** since the last audit.

**How complete is this, plainly.** The gap the previous audit led with has largely closed. Its
single biggest complaint was that the API implemented a requirement completely and no screen called
it; eleven rows have since moved from Partial to Done for exactly that reason. Dependencies can now
be added and removed, plan versions viewed and restored, scenarios composed and adopted, the
incident rota assigned, day rates added and versioned, bulk actions run, the schedule grouped,
the benefits register filtered, objective weights edited, and tags and `earliest_start` set on the
add form. Of 105 API actions, 19 are still never referenced by the client, and most of those are
legitimately server-side jobs. Sixty-five of the eighty R1 requirements are Done and none is Not
done.

The same failure mode has reappeared one level out, and it is the honest headline of this update.
Four substantial new surfaces were built — a read-only public REST API at `/v1` with an OpenAPI 3.1
document, outbound HMAC-signed webhooks with a back-off ladder, a per-person iCalendar feed, and an
inbound incident intake endpoint — together with a data retention policy and purge job. All five are
real, tested and well made server-side. **None of the five has any client control whatsoever.** A
person cannot obtain or revoke their own calendar feed, an administrator cannot create a webhook
subscription or an intake source, and nobody can see or set the retention period from the app;
`grep` for `webhook`, `calendar.php`, `intake` or `retention` across `mobile/lib/` returns nothing at
all. That is why VIEW-09, INT-02, INT-04, INT-07 and ADM-05 are Partial rather than Done, and it is
the clearest example of a build-out scoring better against the code than against the product.

One thing has genuinely regressed, and it is a security defect rather than a missing feature.
`/v1/assignments` in `api/v1.php` takes `plan_version_id` from the query string and applies no
`workspace_id` predicate and no ownership check, so in a tenancy with more than one workspace any
authenticated token — a viewer's included — would read another workspace's plan. It also publishes
plan versions that are not committed: asking the public, read-only API for version 7 on the demo
returns the contents of an unapproved *proposal*, verified live. The parameter is a documented part
of the contract in `docs/openapi.yaml` and `tests/public_api_test.php` asserts nothing about
tenancy. Every other query in `api/` still filters by workspace. This is the first thing that should
be fixed and it is one predicate.

Two rows have moved **down**, and neither is a regression in the code. EST-09 and STAB-10 are policy
switches that are enforced correctly server-side but have no control anywhere in Settings, and both
requirements say in terms that the threshold is "configured" or "configurable". A policy an
administrator cannot reach is the same defect as an endpoint no screen calls, so they are recorded
the same way. REQ-02 also moves down on a closer reading of the requirement, which asks for coverage
"in the planned window"; `qualified_people()` counts everyone qualified in the workspace and applies
no date filter at all.

Where the product is still weakest is reporting and notification delivery. Not one of the four REP
rows is Done: there is still no work-type dimension on estimate accuracy in the UI, no team filter,
no PDF, and the "Schedule email" dialog remains an admitted stub. All seven notification kinds now
fire and `notify()` honours the preference table, but in-app is the only delivery route that exists
— there is no mail transport, push registration or Teams sender anywhere in the repository, so
`channel` records the route a user chose rather than one anything acted on. Settings → Integrations
is no longer misleading: it reads `dbo.integrations` and reports all seven connectors as not
connected, which is true. There are still no native mobile apps; the phone experience is a
responsive layout in the same Flutter web build.

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
| CFG-01 | Create, rename, recolour, reorder, retire work types | Must | R1 | Done | `workspace_config.php` `save_work_type` / `reorder_work_types` / `retire_work_type`; Settings → Work types with an add dialog, a `ReorderableListView` and per-tile rename and retire |
| CFG-02 | Work type attributes | Must | R1 | Done | Was Partial. `AdmSizeRules` in `screens/parts/adm_settings_parts.dart` adds a default-size dropdown and allowed-size chips to `_WorkTypeForm`, which posts `default_size_stamp` and `allowed_sizes`. All eight attributes the requirement lists are now editable |
| CFG-03 | Retiring blocked while open items use it; bulk re-type offered | Must | R1 | Done | Server returns 409 with `open_items`; `_retire()` catches it, shows a re-type picker and reposts with `retype_to_id` |
| CFG-04 | Size classes with band, planning value, class, granularity, WIP flag | Must | R1 | Done | `save_size_class` plus `_SizeClassDialog`; all eight fields editable |
| CFG-05 | Default bands S/M/L/Custom, non-overlapping, validated on save | Must | R1 | Done | Overlap check in `workspace_config.php` returns a 409 naming the fix, shown inline in the dialog |
| CFG-06 | Custom size entered directly (days or hours) or rolled up from tasks | Must | R1 | Partial | Custom stamp, `custom_effort_days` and `rollup_tasks` all work. **The add form offers "Effort in days" only** — `WorkType.sizeUnit` is parsed and read by no screen — **and nothing prevents an item above the largest band being stamped L** rather than split or made Custom |
| CFG-07 | Size classes overridable per work type | Should | R2 | Partial | `size_classes.work_type_id` and the fallback to workspace scope are real. **`_SizeClassesSection` still offers one hardcoded switch bound to `config.incidentWorkTypeId` and `_SizeClassDialog` has no scope picker**, so no override can be created for any other type |
| CFG-08 | Workspace scheduling policy | Must | R1 | Done | `save_policy` versions every field; Settings → Policy edits freeze horizon, planning horizon, change budget, minimum improvement, reserve, max concurrent, min focus and both cadences |
| CFG-09 | Configuration versioned and audited; schedule shows the policy version behind each plan | Should | R2 | Done | Was Partial. `plan_versions_screen.dart` renders `policy v{n}` on each version card and a "Policy version" row in the detail; the screen is reachable from the Schedule by three controls |
| CFG-10 | Configuration export and import as JSON | Could | R3 | Done | `export` / `import`; Settings offers "Export JSON" and an admin-only paste dialog, and the live export matches the Appendix A shape. Minor: neither carries `requirements_template`, so a workspace seeded from an export loses its REQ-03 templates |

### 2.2 Pipeline and intake (PIP)

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| PIP-01 | Add an item with title, type, size, summary, tags, requester, sponsor, needed-by, earliest-start | Must | R1 | Done | Was Partial. `add_work_form.dart` now has a tags field with a live chip preview and an "Earliest start" date picker; both go into the `create` body and both are editable afterwards from the item's edit dialog |
| PIP-02 | Reference from prefix and sequence | Must | R1 | Done | `allocate_ref()` against `ref_sequences`, atomic per prefix; `intake.php` uses the same function |
| PIP-03 | Pipeline list with filtering and sorting by any column | Must | R1 | Partial | Filters all work and `work_items.php` accepts nineteen sort keys plus `dir`. **The UI sort is still a five-option dropdown with no direction toggle and no sortable column headers, and the planned window is still not a column** |
| PIP-04 | Nine statuses, transitions validated against work-type policy | Must | R1 | Done | `set_status` holds an explicit transition matrix and calls `readiness_for()`; 409 with the missing items |
| PIP-05 | Record dependencies and see them on the item and in the schedule | Must | R1 | Partial | The client half is now built: `screens/parts/wc_dependency_dialog.dart` offers direction, finish-to-start or soft and a search, and `_dependenciesPanel()` wires add and a per-row remove to `add_dependency` / `remove_dependency`. **The schedule still never draws or labels a dependency** — no occurrence of "depend" in any schedule source file — so the second half of the requirement is unmet |
| PIP-06 | Split into tasks with their own effort and skill; roll up | Must | R1 | Done | `add_task` / `delete_task` / `rollup_tasks` reached from the Tasks tab. `update_task` exists and no screen calls it — a task can be added and deleted but not edited |
| PIP-07 | Import from Jira or Azure DevOps by query, with field mapping, kept in sync | Should | R3 | N/A | Needs a Jira or Azure DevOps instance. No adapter, query importer, field mapper or sync job, and `_importFromJira()` still opens a dialog saying the import "is configured in Settings → Integrations". This remains the one stub in the repository that reads as the feature. `intake.php` is inbound incident intake, a different requirement |
| PIP-08 | Queue-health strip with oldest wait | Should | R1 | Done | `list` returns `queue_health` with `oldest_days` per bucket, rendered by `_queueStrip()`. The wait is `DATEDIFF(day, wi.updated_at, today())`, so it measures days since last touched rather than days in the state, and every bucket reads 0 on the demo |
| PIP-09 | Discussion thread with @mentions and attachments | Should | R2 | Partial | Thread and @mentions are real — `add_comment` matches person names and calls `notify_person`. **Attachments do not exist at all: no table in `db/01_schema.sql`, no upload endpoint, no file picker** |
| PIP-10 | Bulk re-type, re-size, tag, cancel, assign owner | Should | R2 | Done | Was Partial. `screens/parts/wc_bulk_actions.dart` provides the bulk bar and dialog for all five; the pipeline holds the selection set, renders `WcSelectionTable` and calls `bulk`. Gated to team lead on both sides |
| PIP-11 | History of every change with who, when, before and after | Must | R1 | Done | `history` stitches `audit_events` across nine entity kinds; shown as a History sheet rather than a literal tab |

### 2.3 Work item requirements and readiness (REQ)

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| REQ-01 | Required skills with minimum proficiency and optional effort | Must | R1 | Done | `set_skill_requirement` clamps `min_proficiency` to 1–4 and stores `effort_days`; the item screen adds and removes requirements, and the estimate screen's skill split writes the effort |
| REQ-02 | Coverage per required skill; single points of failure flagged | Must | R1 | Partial | Was Done. `qualified_people()` produces `coverage_count`, `coverage_label` and `single_point` and the item renders "No one qualifies" and "Only <name>" chips. **The requirement asks how many people meet the minimum *in the planned window*, and the query applies no date filter at all** — coverage is workspace-wide, so leave or load in the window changes nothing |
| REQ-03 | Free-text requirements tab with headings, lists, links and acceptance criteria; per-type template | Should | R1 | Partial | Untouched by the build-out, in both halves. The template is applied on create and is seeded, but **`_requirementsTab()` still renders a bare `Text()`** — no markdown, no editor, and the item's edit dialog omits `requirements_text` even though `update` whitelists it — **and the Settings work-type form still omits `requirements_template`**, so no administrator can change it |
| REQ-04 | Readiness checklist per work type, enforced before Ready | Must | R1 | Done | `items_lib.php` `readiness_for()` drives the checks from `requires_estimate` / `requires_benefit`; enforced server-side with a 409 listing what is missing. The checklist is derived rather than admin-editable — only the estimate and benefit rows vary by type |
| REQ-05 | Link to external records by URL with a live status badge | Could | R3 | Not done | `external_url` and `external_ref` are in the schema, in the `update` whitelist and parsed into `models/work_item.dart`. **No screen renders, edits or opens them, and there is no status badge.** The URL half needs no integration and is still absent |

### 2.4 Team, skills and availability (TEAM)

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| TEAM-01 | Skills catalogue; merge and retire | Must | R1 | Done | `skills.php` `save` / `merge` / `retire`; Team & skills → Skills tab wires all three to per-row actions gated on the admin role |
| TEAM-02 | Person profile: role, team, days per week, pattern, max concurrent, min focus, preferences, avoid | Must | R1 | Partial | `people.php save` accepts the whole profile; the client does not. **The edit dialog covers only name, role title, tagline, days per week, prefers and avoid; working pattern, max concurrent and focus blocks are read-only rows.** A team can be chosen when a person is created and never changed afterwards |
| TEAM-03 | Proficiency 0–4, lead endorsement, certifications attached | Must | R1 | Partial | Levels and endorsement are real and reachable from both the person page and the matrix cell picker. **Certification is a single BIT with no issuer, expiry or file; `set_skill` accepts a `certified` flag that no Dart file sends, and there is no attachment table anywhere** |
| TEAM-04 | Skills matrix with proficiency, people at L3+, demand over the horizon, gaps highlighted | Must | R1 | Done | `skills.php matrix` returns cells, `people_at_3_plus`, a single-point summary and `demand_vs_supply`; rendered as the matrix, summary strip and demand panel with single points flagged and over-demand reddened |
| TEAM-05 | Development targets; scheduler prefers pairing that person as a second | Should | R2 | Partial | The scheduler half is implemented (`pl_try_pairing()`) and the pairing switch is now live and writes. **But the switch can only re-send a target that already exists** — no control creates one, and the panel's own empty state says "Set a target level on a person to plan pairing" with nothing that does so, so targets exist only in seed data |
| TEAM-06 | Availability covers leave, training, rota and recurring patterns | Must | R1 | Partial | Leave, training, sickness and rota all reduce capacity through `derive_capacity()`, and `showTmAddLeave` creates records with type, range and a half-day fraction. **There are no recurring patterns: `availability` is a single date pair with no recurrence column.** The only recurring element is `people.working_pattern`, which no screen can edit |
| TEAM-07 | Leave imported from HR and calendar, source-marked, correctable but not deletable | Should | R2 | N/A | Needs an HR system and an M365 tenant. `availability.source` accepts `hr` and `calendar` and `delete_availability` refuses non-manual rows. **But there is no importer, and still no `update_availability` action — so the local half of the rule is "not deletable, not correctable"**, and `delete_availability` itself is called by no screen |
| TEAM-08 | Incident rota per week; that person's reserve rises to the rota percentage | Must | R1 | Done | Was Partial. `screens/parts/adm_rota_panel.dart` lists eight weeks, offers assign per week and a per-person clear, and posts `set_rota` / `clear_rota`; wired into the Availability tab gated on the team-lead role. `capacity.php` applies `rota_reserve_pct` on those weeks, asserted by the engine suite |
| TEAM-09 | Teams grouped into a portfolio; a person loanable to another team for a dated period | Should | R3 | Not done | No portfolio concept and no loan mechanism anywhere in `api/`, `db/`, `engine/` or `mobile/lib/`. Only a flat `teams` table and a `team_id` filter |
| TEAM-10 | Capacity derived nightly; load percentage on the profile and in the lane header | Must | R1 | Done | `cron.php` → `run_nightly` calls `derive_capacity`, which also re-runs on availability, rota and pattern changes; `load_pct_map` feeds the profile's load tile and the colour-banded lane header |

### 2.5 Estimation (EST)

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| EST-01 | Estimate by size class, three-point or task roll-up | Must | R1 | Done | `estimates.php save` branches on all three methods; the estimate screen exposes them as tabs with their own panels |
| EST-02 | PERT expected, standard deviation, P80, implied size class | Must | R1 | Done | `items_lib.php` `estimate_derive()`; all four shown, including the implied stamp |
| EST-03 | Estimate class 5 to 1 with descriptions, defaulted from the size class | Must | R1 | Done | `DP_CLASS_DESCRIPTIONS` and `DP_CLASS_TOLERANCE` served by `class_list()`; a 5→1 segmented picker with the ±tolerance label, defaulted from `default_estimate_class` |
| EST-04 | Effort split by skill, driving what the scheduler matches and allocates | Must | R1 | Done | `save` upserts `skill_requirements.effort_days` from `skill_split`; `model.php` builds `skill_effort` and the planner both matches `min_proficiency` and allocates against it |
| EST-05 | Blended or per-role day rate converting effort to a cost range; rates configured and versioned | Should | R2 | Partial | The configured-and-versioned half is now real and reachable: `AdmDayRatesPanel` gives admins "Add rate", per-row edit, an effective-from picker and an "In force today" marker, calling `save_day_rate`. **The per-role half is still fiction** — `day_rates` has no role or skill column, so `blended_day_rate()` picks one rate for the whole workspace and a non-blended rate is never applied to anybody |
| EST-06 | Estimates versioned with author, date and reason; latest used; changes visible | Must | R1 | Done | New row per save with author and reason; every read takes the top version; versions sheet and history panel on the estimate screen |
| EST-07 | Calibration: actual ÷ most-likely by size class and work type over 12 months, with a plan-at recommendation | Should | R2 | Partial | Twelve-month medians by size stamp and the most-likely/P80 recommendation are real and shown. **The work-type dimension is absent from the UI — `calibration()` groups by stamp only and never joins `work_types`** — though `vw_estimate_accuracy` and the accuracy CSV do now carry a type column |
| EST-08 | Find similar delivered items and copy their estimate | Should | R2 | Done | `similar_for()` matches size stamp and overlapping skills; the "Copy from similar" sheet and its "Use" button populate the three-point form |
| EST-09 | Policy can require a re-estimate before an item enters the committed window when the class is worse than a threshold | Should | R2 | Partial | Was Done; re-scored, not regressed. The gate is real and tested: `engine/commit.php` `reestimate_blocked_changes()` returns 409 naming the item and its class, the nightly auto-apply skips it, and `watch_list` reports the same items. **But `reestimate_class_threshold` is rendered and edited nowhere in `mobile/lib`**, and the live policy returns null, so the requirement's "configured threshold" can only be set by a raw API call and the feature is inert in the demo |
| EST-10 | Assumptions and exclusions recorded and shown wherever the estimate is shown | Must | R1 | Done | Stored per version, edited on the estimate screen, displayed on the item's ROM panel and estimate detail |

### 2.6 Business benefits and prioritisation (BEN)

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| BEN-01 | Benefits with type, value, currency, confidence, realisation start, owner, narrative | Must | R1 | Done | `benefits.php save` validates and stores all of them; the add/edit dialog covers each. Currency is fixed to GBP — the dialog never sends it and `fmtMoneyK` hardcodes the symbol |
| BEN-02 | Non-financial benefits on a qualitative scale with an optional proxy value, still influencing priority | Should | R2 | Not done | `qualitative_scale` is a column the API will store, but no control sets it, the seed always writes null, and `engine/priority.php` scales `annual_value` alone — so a qualitative benefit cannot influence priority. There is no proxy-value concept at all |
| BEN-03 | Priority score from value × confidence, urgency, risk, leverage and age; weights configurable; formula shown on the item | Must | R1 | Partial | A faithful implementation of section 8.4, and the five weights plus the confidence scale are editable in Settings. **The formula is still not shown**: the API sends `weight`, `normalised`, `input` and `p90` per term and `_priorityTermRow` discards all four, rendering a label, a bar and the contribution only, so a reader cannot reproduce the score from the item page |
| BEN-04 | Interrupt items take priority from severity and bypass the benefit case | Must | R1 | Done | `priority.php` scores interrupts from `severityScores` and marks the other terms "skipped: interrupt policy"; severity is set at intake. The severity contribution is also published as the `urgency` term with `alias_of`, so the breakdown sums to the score |
| BEN-05 | Benefits register with filters by type, owner, status and quarter, and totals in plan, realised and at risk | Must | R1 | Done | Was Partial. The Register tab now posts all four filters to `benefits.php list` and renders them as four dropdowns plus a clear control, scoped to the tab so the three totals stay workspace-wide. Verified live |
| BEN-06 | Benefit owner records realised value at the configured cadence; planned against realised by quarter | Should | R2 | Partial | `record_realisation`, the dialog and the quarterly chart all exist, and there is now a prompt — `notify_realisations_due()` raises a `realisation_due` notification from the nightly run. **There is still no configured cadence** — no column, no setting, quarters hardcoded and planned values always `annual_value / 4` — **and the prompt fires once per benefit, ever**, so a later period falling due is never chased |
| BEN-07 | Delivery lead can pin or override priority with a reason and an expiry | Must | R1 | Done | `override_priority` / `clear_override` require the delivery-lead role, demand a reason, reject a past expiry and audit; dialog, in-force note and Clear on the item page |
| BEN-08 | Register exportable to CSV and to Power BI via a read-only dataset | Should | R2 | Partial | CSV is done. Power BI is closer: `/v1/benefits` is a read-only, paginated, token-authenticated resource. **But there is still no benefits SQL view, no dataset shaped for Power BI, no row-level security, and the Power BI card in Settings is a disabled switch reading "No connector is built yet"** |

### 2.7 Automated scheduling (SCH)

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| SCH-01 | Plan honouring skills, capacity and reserve, availability, dependencies, earliest start, max concurrent, focus blocks | Must | R1 | Done | `pl_meets` for skills, `pl_free`/`pl_reserve_free` for capacity minus reserve, `derive_capacity()` for availability, dependency recursion and `earliest_start` in `pl_place_item`, `max_concurrent` in `pl_try_run`. Focus blocks hold by construction in the heuristic and are explicit in `solver.py` |
| SCH-02 | Optimises for value-weighted early completion, due dates, balanced load, low context switching and minimal change; weights configurable and shown | Must | R1 | Done | Was Partial. `AdmObjectiveWeights` renders a numeric field per term with its meaning and default, wired through the Settings draft to `save_policy`, which merges them and writes a new policy version. Admin-gated, at Settings → Priority & objective |
| SCH-03 | Proposal, never a silent change | Must | R1 | Done | `run_propose` stores the candidate as `proposed`; only `changes.php commit` or an explicit manual move creates a committed version. `auto_apply_outside_horizon` defaults off and touches only changes wholly outside the freeze horizon |
| SCH-04 | Percentage allocation in 25% steps; granularity follows the size class | Must | R1 | Done | `pl_allocs()` returns 100/75/50/25 for day granularity and 100/50 for half-day and week; `granularity` comes from the item's size class |
| SCH-05 | Infeasible items on the watch list with the reason and the smallest change that would help | Must | R1 | Done | `pl_unsched()` and `pl_skills_gap()` produce a reason and a suggestion per item; `build_watch_list()` turns them into the Overview watch list. Verified live, ten entries each with a suggestion |
| SCH-06 | Fix an assignment (person, dates or both) and the scheduler plans around it | Must | R1 | Done | `plan.php` `fix_assignment` / `unfix`, delivery-lead only, with `fixed_person` and `fixed_dates` independent; the block dialog has both switches and pass 1 pre-loads locked rows |
| SCH-07 | Drag an assignment, see the knock-on before saving, recorded as a manual change | Must | R1 | Done | `move_assignment` with `preview: true` returns knock-on, stability cost and warnings; the drag dialog shows them before the confirm, and the apply path records a decided manual proposal and `person_change_log` rows |
| SCH-08 | Heuristic preview within 2 s; full optimisation as a background job with a configurable budget | Must | R1 | Done | Measured live at 0.33–0.43 s for a person-away what-if on the demo. `solver_budget_seconds` is editable in Settings and passed to the CP-SAT service; `cron.php` is the background job. The old caveat is resolved — the scenarios composer is now the UI for `replan.php preview` |
| SCH-09 | Committed, planned and indicative windows | Must | R1 | Done | `model_state_for()` labels every assignment; the schedule tints and locks committed weeks and draws indicative blocks with a dashed border and hatching |
| SCH-10 | Incidents consume reserve first, then displace the person's lowest-priority planned work as a proposed change | Must | R1 | Done | `pl_consume()` takes reserve first for interrupt items and `pl_place_item` calls `pl_incident_target()` → `pl_lowest_priority_on()` → `pl_displace()` when the run would miss the response window; the displaced item re-enters the queue and the diff surfaces it |
| SCH-11 | Named what-if scenarios, compared with the committed plan before adopting | Should | R2 | Done | Was Partial. `scenarios_screen.dart` at `/schedule/scenarios`, reachable from a Schedule button and a narrow-width pill, composes five kinds of edit, calls `replan.php preview` and shows a before/after summary table against the committed plan with the improvement percentage, then `scenario_save` and `scenario_adopt` behind a confirmation |
| SCH-12 | Prefer pairing a person with a development target when the objective cost is below a threshold | Should | R2 | Partial | `pl_try_pairing()` is a real implementation gated on `pairing_cost_threshold_days`. **It can only ever fire on seeded data, because no UI creates a development target (see TEAM-05)** |
| SCH-13 | Multi-team scheduling across a portfolio | Could | R3 | Not done | No portfolio exists; `build_model()` takes one workspace's active people as a single pool and carries `team_id` as a label |
| SCH-14 | Record inputs hash, policy version, objective score, solve time and whether the optimum was proved | Should | R2 | Done | All five stored on every `plan_versions` row. Verified live on v7: a SHA-256 `inputs_hash`, `policy_version 1`, `objective_score`, and `solver_stats` with solve seconds and `provedOptimal` |

### 2.8 Schedule stability (STAB)

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| STAB-01 | Freeze horizon locks committed assignments; manual changes inside need an approver and a reason | Must | R1 | Done | The planner never moves locked or frozen rows; `move_assignment` returns 409 without a reason inside the horizon and stores "Approved by …" in `guardrail_reason`; `apply_guardrails` marks such changes `needs_approval` |
| STAB-02 | Each moved assignment-day carries a stability cost, penalised in the objective | Must | R1 | Done | `diff_change()` costs moved allocation-days inside committed and planned windows; `pl_item_cost()` charges `stabilityPlanned × moved` when choosing a placement |
| STAB-03 | Change budget per person per week; proposals over it held with the reason | Must | R1 | Done | `apply_guardrails` accumulates per person-week including prior committed usage, holds the excess as `held_budget` and names the person, the days and the week. Asserted by the engine suite |
| STAB-04 | Minimum improvement threshold; proposals below it shown but never applied automatically | Must | R1 | Done | `below_threshold` from `improvement_pct` turns every change into `held_threshold`; the Changes screen says so in the header |
| STAB-05 | Cadence of propose nightly, commit weekly; urgent triggers start an immediate cycle limited to the affected people | Must | R1 | Partial | Was Done; re-scored. The urgent half is fully real — `start_urgent_cycle()` runs a scoped cycle from an incident arriving, sickness or leave inside the freeze horizon, and a leaver, best-effort so it never fails the originating request, asserted end-to-end. Propose-nightly is real. **The commit-weekly half is not implemented at all**: `commit_cadence` is a string that is displayed and used only to compute `next_commit_at`, a field the client never reads. No job, deadline or reminder enforces or surfaces a weekly commit |
| STAB-06 | Assignments beyond the planning horizon are indicative and cost nothing | Must | R1 | Done | `diff_change()` and `pl_item_cost()` both skip days past `plannedEndDi`, and `summary_total_days()` clamps at `planned_end` |
| STAB-07 | Per-person stability view over 8 weeks with reasons; team and workspace stability trend | Must | R1 | Done | `people.php get` returns `change_history` and a stability note; the person page renders the eight-week panel with reasons; `changes.php mine` feeds My week; the trend is on Overview and Reports |
| STAB-08 | Plan stability index, rolling four weeks, on the overview and in reports | Must | R1 | Done | `stability_index()` in `summary.php` against `stability_weeks`; shown on Overview with its definition and as the Reports trend |
| STAB-09 | Upward re-estimate extends the same assignment unless it breaks the needed-by date | Must | R1 | Done | `pl_try_keep()` reproduces the committed slot at the same person, start and allocation and extends it; `pl_breaks_needed_by()` rejects the keep only outside the freeze horizon |
| STAB-10 | Small incoming work fills existing gaps in the planned window before displacement is considered | Must | R1 | Partial | Was Done; re-scored. The heuristic honours it: `planner.php`'s queue sort puts items flagged `small` by `model.php` ahead of larger incoming work, and `tests/engine_test.php` asserts the flag tracks the policy value and that inverting it inverts the order. **Two gaps against the requirement's "below a configurable size": `small_fill_threshold_days` has no Settings control, and `engine/solver.py` contains no occurrence of "small", "fill" or "gap"** — `cpsat_client.php` ships both the flag and the threshold to a solver that reads neither, so the requirement silently stops holding on a CP-SAT workspace |
| STAB-11 | Non-urgent triggers batched until the next scheduled proposal | Must | R1 | Done | `add_trigger()` writes a `replan_triggers` row with a class from every mutating endpoint; nothing replans on edit; `run_propose` consumes the unprocessed rows and stamps them |
| STAB-12 | Mark an item or a person protected for a period, raising the stability cost | Should | R2 | Partial | The engine half is complete: `protected_until` doubles the cost in both `diff.php` and `pl_item_cost()` and produces a "Protected · stability cost doubled" chip, and both `work_items.php save` and `people.php save` accept it. **No screen sets it and no screen shows it** — it appears in Dart only as a parsed field |

### 2.9 Change proposals, review and approval (CHG)

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| CHG-01 | Each change as before and after, with trigger, objective terms, stability cost and people affected | Must | R1 | Done | `diff.php` produces before/after envelopes, cost, `inside_freeze` and `affected_person_ids`; `explain.php` adds the headline, plain-English reason and impact chips; the proposal carries its triggers. Verified live |
| CHG-02 | Accept, reject or edit each change, or accept all that pass guardrails | Must | R1 | Done | `decide`, `edit` and `reject_all` are all called from the Changes and change-detail screens, which preselect every guardrail-passing change and then commit. The server's own `accept_all_passing` action is dead code, but the same outcome is reached by looping `decide` |
| CHG-03 | Held changes cannot be accepted without an override permission and a reason | Must | R1 | Done | `decide_change()` refuses `held_budget` and `held_threshold` without the admin role *and* a reason; the client blocks non-admins with the guardrail sentence and forces an override reason dialog |
| CHG-04 | Before-and-after summary of late items, quarterly value, people over 100%, single-skill dependencies, days changed and stability index | Must | R1 | Done | `plan_summary()` computes all six; stored on the proposal and rendered as a before/after table on the Changes screen |
| CHG-05 | Accepting creates a new committed version; the previous remains viewable and restorable | Must | R1 | Done | Was Partial. `plan_versions_screen.dart` calls `versions`, `version` and `restore`, is routed at `/schedule/versions` and is reachable from three Schedule controls, with restore gated on the delivery-lead role to match the server |
| CHG-06 | Affected people notified before the change takes effect, with the reason, and can comment; policy can require acknowledgement inside the horizon | Must | R1 | Done | Notification happens at propose time with the reason, comments work, and `acknowledge` exists. `require_ack_inside_horizon` is read at commit time and stamped on `change_proposals.ack_required`, so turning it off stops asking rather than hiding the ask; `mine` drives My week's acknowledgement card. Tested on and off |
| CHG-07 | Approval roles configurable: who approves inside the horizon, who overrides guardrails, whether auto-apply is allowed outside it | Must | R1 | Partial | The approval rules are enforced but hardcoded: `require_role('delivery_lead')` to approve and `has_role('admin')` to override, **neither configurable — `workspace_config.php` has no approver-role action and `scheduling_policies` has no approver column**. The auto-apply clause is done: `auto_apply_outside_horizon` is read by the nightly run, which accepts and commits every pending change that passes all guardrails and falls wholly outside the freeze horizon, audits each, and re-proposes the rest |
| CHG-08 | A proposal expires at the next cycle, which notes what was carried over | Should | R1 | Done | `run_propose` supersedes every open proposal, collects the undecided headlines and writes `carried_over_note`, shown as a chip on the Changes screen |

### 2.10 Schedule and overview views (VIEW)

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| VIEW-01 | Lane per person across a selectable horizon, blocks coloured by type and labelled | Must | R1 | Done | `schedule_screen.dart` with a Weeks / Days / Months zoom (6, 2 and 26 weeks); blocks carry reference, title and size stamp |
| VIEW-02 | Committed window distinct and locked, today marked, leave and rota hatched, indicative dashed | Must | R1 | Done | `SchHatchPainter` and `SchDashedBorderPainter` in `schedule_widgets.dart`; committed weeks tinted with a lock glyph, today an orange marker |
| VIEW-03 | Lane headers with name, role and load percentage, colour-coded against the target band | Must | R1 | Done | `SchLaneHeader` shows avatar, name, role title and load, banded by `schLoadColour` against `target_load_min` / `max`. Asserted by the HTTP smoke suite |
| VIEW-04 | Filter by team, work type, skill and item; group by person, item or work type | Must | R1 | Done | Was Partial. `SchGroup.{person,item,workType}` with a group control in the toolbar and in the phone sheet, re-laning client-side; all four filters still reach the server |
| VIEW-05 | Proposed changes overlaid with the moved blocks highlighted | Should | R1 | Done | `overlay_proposal_id` on `schedule`; the overlay toggle draws the proposed plan with a ghost at each moved block's committed position |
| VIEW-06 | Overview with committed deliveries, load, stability, reserve use, pending proposals and watch list | Must | R1 | Done | `overview.php get` returns every section and the screen reads all six. Verified live; covered by the overview suite |
| VIEW-07 | Person page with assignments, skills, availability, preferences and personal stability history | Must | R1 | Done | `person_screen.dart` has all five panels plus the rota and the weekly change history |
| VIEW-08 | Item page with summary, requirements, skills, dependencies, plan facts, estimate, benefits, tasks, schedule and history in tabs | Must | R1 | Done | Seven tabs; skills coverage, dependencies and plan facts are panels on the Overview tab and history is a sheet, which reads as the mockup intends |
| VIEW-09 | Export the schedule to PDF and to iCalendar per person | Should | R2 | Partial | Was Not done. The iCalendar generator is real and complete — `api/calendar.php` emits a folded RFC 5545 `VCALENDAR` of one person's committed assignments from a revocable token, excluding leave deliberately for ADM-05 reasons. **But no screen calls it**: `my_feed` and `revoke` are referenced nowhere in `mobile/lib/`, so a person cannot obtain or revoke their feed URL from the app, and `calendar_feeds` is empty. **PDF does not exist at all** — no generator in `api/`, no PDF package in `pubspec.yaml`, and every export control produces CSV |

### 2.11 Notifications and collaboration (NOT)

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| NOT-01 | Notifications for seven events | Must | R1 | Done | All seven are generated: `change_proposed` and `approval_requested` by `run_propose`; `change_committed` and `item_assigned` by `engine/commit.php`; `estimate_requested` by `work_items.php`; `realisation_due` and `watch_list` by `run_nightly`, deduplicated per week. **The named gap was not fixed: `plan.php move_assignment` still raises no `item_assigned`** — a manual reassignment notifies the receiving person as `change_committed` only, bypassing their per-kind preference. `request_estimate` also has no client control, so that kind is reachable only through a status change |
| NOT-02 | Channels in-app, push, email digest and Teams, chosen per kind with a cadence | Must | R2 | Partial | `notification_prefs` persists all four switches and the cadence per kind, the Notifications screen edits them, and `notify()` reads the table: in-app off writes no row, and `channel` is set from the user's own choices. **There is still no push, email or Teams sender** — no SMTP, mail, PHPMailer, FCM, APNs or Graph call anywhere — so `channel` records the route chosen rather than a delivery that happened |
| NOT-03 | Urgent notifications bypass digests | Must | R2 | Partial | The `urgent` flag is set from `inside_freeze`, rendered as a red chip, and `notify()` skips the digest and Teams branches entirely when it is set, asserted in the policy suite. **There is still no digest job to bypass**, so the branch is correct but untestable end to end |
| NOT-04 | Weekly digest of next week's plan and changes since the last one | Should | R2 | Not done | No digest job and no mail transport. The three scheduled scripts are the replan cycle, the webhook dispatcher and the retention purge; none summarises a person's week, and the stored `digest` preference is never consumed |
| NOT-05 | Comments on items and proposals support @mentions and link to the exact change | Should | R2 | Partial | @mentions are parsed on **work-item** comments only and link to the item, not to a change. **Change-proposal comments do no mention parsing** — they notify everyone affected under kind `change_proposed` — **and `mention` is still absent from `NOTIFICATION_KINDS`**, so such notifications appear in nobody's preference list and honour no per-kind setting |

### 2.12 Reporting and analytics (REP)

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| REP-01 | Seven reports | Must | R2 | Partial | Five are there: stability trend, load planned against actual, estimate accuracy, delivered by type per month, and cycle time. Benefit realisation by quarter and skills demand against supply exist but on the Benefits and Team screens, not in Reports. **Accuracy still groups only by size on screen**, though `vw_estimate_accuracy` and the CSV now carry a work type |
| REP-02 | Filter by team, period and work type; export to CSV and PDF; schedule by email | Should | R2 | Partial | Period only (4w / 12w / 12m). **No team or work-type filter, no PDF, and the "Schedule email" dialog is still an admitted stub** — "Scheduled email is not wired up in this build." Worth knowing: Export is not a download either — `showTmCsvDialog` shows the CSV in a selectable text box with a copy button |
| REP-03 | Read-only analytics dataset for Power BI with row-level security matching app permissions | Should | R3 | Partial | Two views exist, `vw_assignments_committed` and `vw_estimate_accuracy`. **No row-level security of any kind — no security policy, no predicate function, no `SESSION_CONTEXT` — and no benefits or stability view.** `/v1` is a workspace-scoped read-only surface Power BI could consume instead, but it carries the caller's role rather than row-level security |
| REP-04 | Every metric has an in-app definition | Must | R2 | Partial | Much improved: `mobile/lib/widgets/adm_metrics.dart` carries eleven definitions with formula, inclusions and exclusions, surfaced through `TmMetricTitle` on Team & skills, Person and the Settings day rates, on top of the four `reports.php` returns. **Remaining gap: the Benefits screen and every stat tile on Overview and the Pipeline still carry no definition** |

### 2.13 Administration, security and audit (ADM)

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| ADM-01 | Sign-in through Entra ID by OpenID Connect; no local passwords | Must | R1 | Partial | The verification path is real: `oidc_login` fetches the tenant JWKS, checks the RS256 signature, `kid`, audience, issuer and expiry, and maps group claims to roles. No password is stored anywhere. **It is unreachable: no tenant is configured so it answers 501, there is no MSAL or PKCE client flow, and the sign-in button is disabled.** The only working path is `dev_login`, which takes a bare user id with no credential of any kind |
| ADM-02 | Seven roles, documented, enforced server-side | Must | R1 | Done | `DP_ROLE_RANK` in `lib.php` with 49 `require_role()` call sites across the endpoints, re-read from the database on every request so a role change applies without re-login, and documented in Settings → Teams and roles. Verified live: a team-member token is refused retention, webhook and deactivate actions with 403 |
| ADM-03 | Users provisioned from the directory; leavers deactivated automatically with future assignments flagged | Should | R2 | Partial | The client gap is closed: `person_screen.dart` `_deactivate()` calls `people.php deactivate` behind a confirmation stating how many future assignments are affected, and the control is omitted rather than 403'd for non-admins. The server notes every future assignment as needing reassignment and raises an urgent trigger. **Provisioning is still entirely absent** — no SCIM endpoint, no group-sync job, and `oidc_login` refuses an unknown identity, so there is not even just-in-time creation; deactivation is admin-initiated, never automatic |
| ADM-04 | Every create, update, delete, approval and configuration change audited; searchable and exportable | Must | R1 | Done | `audit()` records actor, time, entity, label, before and after JSON and reason from about eighty-four call sites including config changes, approvals and commits; `audit.php` gives entity, action, actor, free-text and date filters, paging and CSV, exposed in Settings. The export lands in a clipboard dialog rather than a downloaded file |
| ADM-05 | Personal data minimised; leave reasons never stored; retention policy removes plan history after a configurable period | Must | R1 | Partial | Was Partial for a different reason — the retention half now exists. Data minimisation is still honoured deliberately: `availability` holds a type and nothing else and `add_availability` drops any reason. `api/retention.php` adds `get` / `save` / `preview` / `purge` over new `workspaces.plan_history_months` (24) and `audit_retention_years` (7) columns; the scan protects the committed version, the newest superseded one and anything a proposal references, and the purge writes its audit row before trimming the audit table. `cron_retention.php` is the job. **But `grep` for retention across `mobile/lib/` returns nothing**, so no administrator can see the period, change it, preview a purge or run one from the app. `intake_log.payload` and `notifications` are covered by no retention rule at all |
| ADM-06 | Administrators manage day rates, skills catalogue, teams, integrations and notification defaults | Must | R1 | Partial | Day rates are now genuinely editable (see EST-05), and skills, work types, size classes and policy all save. **Three gaps remain: there is still no team CRUD endpoint anywhere — `save_team` exists in no PHP file, and the role dropdown in Teams & roles has `onChanged: null` with an info box saying role changes are "not available in this build"; integrations are read-only; and the "notification defaults" table is `notifications.php prefs` scoped to the signed-in user, so it shows an administrator their own preferences rather than editable workspace defaults** |
| ADM-07 | Multiple workspaces in one tenancy, a user able to belong to more than one | Should | R3 | Partial | The tenancy model is sound in principle — every table carries `workspace_id` and, with the single exception recorded under NFR-SEC-02, every query filters on it. **`users.workspace_id` is a single foreign key, the JWT carries one workspace, there is no switcher and the seed creates one workspace**, so a user cannot belong to two |

### 2.14 Integrations (INT)

The picture here has changed materially and in two directions. Settings → Integrations is no longer
misleading: `workspace_config.php` now selects from `dbo.integrations` and `_IntegrationsSection`
renders one card per returned row, so all seven connectors report "Not connected" with a disabled
switch noting "No connector is built yet" — which is true, because none of the six vendor connectors
exists. Against that, three pieces of integration that need no vendor tenant **have** been built and
work: a read-only public REST API, outbound webhooks, an inbound incident intake, and a per-person
iCalendar feed. Every one of them is configurable only by an authenticated API call — there is no
Settings panel for webhooks, intake sources or calendar feeds, and no scheduled task is registered
for the webhook dispatcher. The four rows still marked N/A genuinely need an external system this
box does not have, but the absence is of the adapter, not only of the remote service.

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| INT-01 | Jira and Azure DevOps import, sync and write-back | Should | R3 | N/A | Needs a Jira or ADO instance. No client, query importer, field mapper or write-back; the only occurrence of "jira" is a seeded, disabled `integrations` row. In its place: a prose panel on the Pipeline describing how the import "is configured" |
| INT-02 | ServiceNow creates Incident items above a severity threshold | Should | R3 | Partial | Was N/A. `api/intake.php` is a real inbound endpoint: authenticated by `hash_equals` against a per-source secret, `intake_pluck()` maps fields by configurable path, `intake_severity()` normalises 1–4, critical/high/moderate/low and P1–P4 through an optional map, the `severity_threshold` check records and ignores anything below it, and a repost of the same `external_ref` returns the existing item rather than raising it twice. It sets severity, scores priority and starts an urgent cycle. **Gaps: it is push-only — nothing polls or subscribes, so ServiceNow must be made to push — no client control exists, so sources can only be created by an admin API call, and the demo has none configured** |
| INT-03 | HR or leave system imported nightly as availability | Should | R2 | N/A | Needs an HR system. No importer and no scheduled job. In its place: `availability.source` accepts `hr`, and leave is entered manually. `intake.php` is the shape such an importer would follow, but nothing writes availability from outside |
| INT-04 | Microsoft 365 out-of-office read; committed assignments published as an iCalendar feed | Should | R2 | Partial | Was N/A. The publish half now exists and is well made — see VIEW-09 — with RFC 5545 folding, exclusive all-day `DTEND`, `TRANSP:TRANSPARENT` for indicative work and leave deliberately excluded. **Two gaps: the out-of-office read half is entirely absent (no Graph call anywhere), and there is no client control, so no person can obtain or revoke their feed URL from the app** |
| INT-05 | Timesheets imported as actual effort | Could | R3 | N/A | Needs a timesheet system. No importer. In its place: `work_items.actual_effort_days` and `stability_weeks.actual_load_pct` feed the accuracy and load reports, populated by the seed |
| INT-06 | Microsoft Teams cards for proposals, approvals and digests, with accept and reject | Should | R2 | N/A | Needs a Teams tenant. No webhook, adaptive card or action handler. In its place: a `teams` boolean in `notification_prefs` that a user can toggle and which `notify()` records as a `channel` value nothing acts on |
| INT-07 | Public REST API (OpenAPI 3.1) and outbound webhooks | Should | R2 | Partial | Was Not done, and this is the largest genuine change in the update. `router.php` routes `/v1` into `api/v1.php`, which serves ten resources GET-only behind the normal token, with cursor pagination and RFC 9457 `application/problem+json` errors, documented by a real OpenAPI 3.1.0 document at `docs/openapi.yaml` with a `webhooks:` section. `engine/webhook_lib.php` derives the four events from the audit log as an outbox, signs each body `X-Dispatch-Signature: sha256=<HMAC-SHA256>` and backs off 1m/5m/30m/2h/6h before abandoning; `webhooks.php` gives an admin save, rotate, delete, test, deliveries, retry and run. **Two gaps keep it off Done: there is no client control whatsoever, so an administrator can only subscribe with a curl call, and the dispatcher is not wired to a scheduled job — `cron_webhooks.php` carries its `schtasks` line in a comment and nothing registers it.** See also the tenancy defect in `/v1/assignments` under NFR-SEC-02 |

### 2.15 Mobile (MOB)

The client is one Flutter codebase built **for web only**. `mobile/` contains `web/` and no `android/`
or `ios/` directory, `mobile/build/` contains no platform build but `web` (the other entries are
`flutter test` tooling artefacts), and `pubspec.yaml` carries no platform plugin — no `local_auth`,
no `firebase_messaging`. The phone experience is a responsive layout below 700 px in the same web
build. Judged on that basis:

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| MOB-01 | Native iOS and Android apps with parity for My week, item, proposals, add work, notifications and self-service | Must | R2 | Not done | No native app exists, and Flutter could have targeted one. In its place: a responsive web phone layout with bottom tabs (My week, Pipeline, Changes, More) that does cover the whole parity list — proposal review and approval included — because every route renders at every width |
| MOB-02 | Schedule read-only on tablets, simplified per person on phones | Should | R2 | Done | Was Partial. Both halves are implemented: `canPlan && Breaks.isDesktop(context)` is passed into the grid, so at tablet width the lane view renders with no draggable blocks, and `_phoneBody` replaces lanes with a group control, a lane dropdown, a summary and a per-week block list including away days. One caveat: the page-level "Propose replan" button is not width-gated, so the lane view is read-only on a tablet but the page is not quite |
| MOB-03 | Offline reading of My week, items and proposals; actions queued and confirmed on reconnect | Should | R2 | Partial | `services/my_week_cache.dart` caches the last My week payload per person and week with a staleness banner, actions disabled while offline and a clear on sign-out. **Items and proposals are not cached and there is no offline action queue at all** — nothing replays a mutation on reconnect |
| MOB-04 | Push through APNs and FCM with deep links | Must | R2 | Not done | No APNs, FCM or token registration, and no deep-link handler; the `push` preference is a column nothing consumes. `flutter_service_worker.js` is the stock asset-precache worker, not a push subscriber. In its place: in-app links and an unread badge |
| MOB-05 | Biometric unlock; sessions follow conditional access | Must | R2 | Not done | No biometric unlock — `pubspec.yaml` carries no `local_auth` — and conditional access depends on the Entra flow ADM-01 shows is unreachable. In its place: a seven-day HS256 JWT in `shared_preferences` restored silently on launch, which is weaker than the requirement rather than a variant of it |
| MOB-06 | Platform conventions respected while keeping one visual identity | Must | R2 | Partial | Material 3, light and dark themes, bottom tabs on phone and one visual identity throughout. **Browser conventions, not platform ones: no back-gesture handling, no share sheet, no dynamic type** |
| MOB-07 | Distributed through Intune and the public stores | Must | R2 | N/A | Needs an Intune tenant and store accounts, and there is no signing configuration or store metadata either. In its place: `flutter build web --release` served from a URL |

## 3 Non-functional requirements

Most of the eighteen are claims about hosting, operations or assurance that a single-box local
implementation cannot make, whatever the code does. Two are structural — they depend on how the
system is built rather than where it runs — and those are the ones worth judging. One that was
structurally met at the last audit no longer is.

### Structurally met

- **NFR-DATA-01 (personal data minimisation).** Met, and deliberately so. `availability` carries a
  type and a fraction and no reason, `add_availability` discards any reason in the request, and the
  schema says so in a comment. The new surfaces respect it: `/v1/people` returns only the ADM-05 set,
  and the iCalendar feed excludes leave on purpose. One new caveat: `intake_log.payload` stores the
  entire inbound ticket verbatim, and a real incident routinely carries a caller's name, email and
  free-text description — and nothing purges that table. The UK-residency and DPIA halves are hosting
  and process matters, not applicable here.
- **NFR-I18N-01 (British English, configurable dates, currency and working week).** Largely met:
  British English throughout, and `workspaces` carries time zone, working days, hours per day and
  currency, all honoured by the engine and the client. The "translation-ready" clause is not met —
  `intl` is present but there are no `flutter_localizations`, no ARB files and no extracted strings.

### Partly met, and measurable here

- **NFR-SEC-02 (role-based access in the API, row-level tenancy by workspace). Regressed.** The role
  clause still holds: seven ranked roles enforced by `require_role()` at 49 call sites and re-read
  per request, and the new surfaces are gated correctly — `webhooks.php` and the retention mutations
  are admin-only, `v1.php` sits behind the normal middleware and answers 401 without a token,
  `intake.php` authorises on a per-source secret with `hash_equals`, and all four new tables carry
  `workspace_id`. **The tenancy clause no longer holds without exception.** `/v1/assignments` takes
  `plan_version_id` from the query string and its `WHERE` clause carries no `workspace_id` predicate
  and no ownership check, so any authenticated token would read another workspace's assignments —
  person names, item references and titles, dates and allocations. It also ignores version status:
  verified live, `GET /v1/assignments?plan_version_id=7` returns the contents of a *proposed*,
  uncommitted version from an API that advertises the committed plan. The parameter is documented in
  `docs/openapi.yaml` and `tests/public_api_test.php` asserts nothing about tenancy. It is not
  observable on this demo because only one workspace is seeded. A lesser instance: `calendar.php`
  `my_feed` and `revoke` accept a `person_id` and check the team-lead role but never that the person
  belongs to the caller's workspace. The OWASP ASVS verification and the dependency and container
  scanning remain undone — there is no pipeline of any kind in the tree.
- **NFR-PERF-01 (API reads within 300 ms at p95).** Met on the demo and better than last time; worst
  of three was 15 ms for `changes.php current`, 20 ms for `plan.php schedule`, 40 ms for
  `work_items.php list` and 41 ms for `overview.php get`. The last is not an optimisation — neither
  `overview.php` nor `watchlist.php` has changed since before `dbbec9c` — so the earlier 328 ms
  reading was a cold measurement rather than the steady state. The 1.5 s first-paint target is still
  untested, and the release bundle transfers 4.5 MB with 3.85 MB of it `main.dart.js`.
- **NFR-PERF-02 (heuristic preview within 2 s).** Met at demo scale — 0.33 to 0.43 s end to end for
  a person-away what-if over 8 people and 42 open items — but **not tested at the stated scale of 50
  people and 500 open items**, and the heuristic's cost model re-simulates the grid per candidate, so
  the scaling is not obviously linear.
- **NFR-PERF-03 (50 lanes over 26 weeks without lag).** Not verified. The demo has 8 lanes; lanes
  render through a `ListView.builder` and the months zoom does draw 26 weeks.
- **NFR-SCAL-01 (200 people, 5,000 items, 24 months of history, 20 workspaces).** Not verified, and
  the last clause is contradicted by ADM-07 — one workspace is seeded and a user belongs to one.
- **NFR-DATA-02 (audit kept 7 years, plan versions 24 months configurable).** Much improved, and now
  partly met by design rather than by accident. Three of the four clauses hold: the periods are real
  stored columns on `dbo.workspaces` with exactly the defaults the requirement names, they are
  settable and audited through `retention.php save` under the admin role, and `retention.php purge`
  is a careful implementation with `cron_retention.php` as its entry point. It stays partly met
  because nothing in the client can set or see the policy, and because the weekly `schtasks` line is
  a comment in the file rather than an installed job.
- **NFR-ACC-01 (WCAG 2.2 AA).** Partly, and materially better than at the last audit: the headline
  gap is closed. Every schedule block now carries a `FocusNode` and a visible focus border, and
  `_onKey` implements arrow-key navigation between blocks and lanes, shift-arrow nudges and
  reassignment, Enter to confirm and Escape to cancel, each step announced through
  `SemanticsService.sendAnnouncement` — drag is no longer pointer-only. Colour is still never the
  only carrier of meaning and reduced motion is respected. But `Semantics` appears in only nine
  files, `textScalerOf` is consulted in exactly one place, Flutter web's canvas rendering remains a
  standing obstacle to assistive technology, and no audit has been run.
- **NFR-OBS-02 (every plan version reproducible from its stored inputs and policy version).** Partly,
  and unchanged: `policy_version`, a SHA-256 `inputs_hash`, the objective score and solver statistics
  are stored on every version, **but only the hash is kept, not the inputs** — `model_inputs_hash()`
  hashes the model and discards it — so a version can be shown to have had different inputs and
  cannot be re-solved from what is stored. One partial exception: `scenario_save` stores its edits
  inside `solver_stats` and `scenario_adopt` replays them, so a scenario is re-runnable against
  today's data.

### Hosting and operations claims, out of scope here

**NFR-AVAIL-01** and **NFR-AVAIL-02** (99.5% availability, RPO 1 hour, RTO 4 hours, geo-redundant UK
backups), **NFR-SEC-01** (Entra conditional access, TLS 1.2+, encryption at rest with customer-managed
keys), **NFR-SEC-03** (Azure Key Vault, managed identities — locally the equivalent is a gitignored
`api/config.php`), **NFR-OBS-01** (structured logs, traces, metrics and dashboards), **NFR-MAINT-01**
(Terraform environments and blue-green deployment with rollback), and **NFR-COMP-01** (browser matrix
untested; iOS and Android have no app at all). The two new scheduled scripts do not move NFR-OBS-01:
each echoes a single line to stdout, `webhook_lib.php` contains no logging call at all, and the only
`error_log` calls in `api/` are three unstructured dumps. Solver duration per plan version remains
the one thing in that family that exists. **NFR-USE-01** (a delivery lead completes the weekly review
in under 20 minutes) is a usability target that needs a pilot, not a code check; the review flow it
depends on — open proposal, accept all passing, commit — is in place.

## 4 What is actually verified

The verification bar in `CLAUDE.md` is real and it passes, though the bar itself is now out of date:
it says "all five PHP suites" and `tests/run_all.php` runs **eight**. Every one ran green during this
audit (engine; workspace config, people and skills; work items, estimates and benefits; overview,
reports and watch list; the plan, proposals and changes HTTP smoke; the public API, webhooks and
calendar feed; data retention and purge; and the policy switches, notifications and urgent cycle),
re-seeding before and after.

The assertions are requirement-aware rather than cosmetic: the change budget holding at the limit, an
improvement below the threshold being held as information, the rota person's reserve rising to the
rota percentage while everyone else holds the standard percentage back, every watch-list entry
carrying a suggestion, nothing outside the freeze horizon being labelled committed, and every lane
header carrying a load percentage. `tests/policy_notifications_test.php` holds each policy switch to
the same standard — every one is asserted with it on and again with it off — and follows an urgent
trigger through to the scoped proposal it produces, a turned-off preference through to the
notification row that is consequently never written, and an incident's priority breakdown through to
the score it has to add up to. What the new public-API suite does **not** assert is tenancy, which is
why the `/v1/assignments` defect in section 3 survived it.

`engine/test_solver.py` checks the CP-SAT model's hard constraints against a hand-built model: level-4
work going to the only qualified person, nobody over 100% on any day, an unqualified item reported
unscheduled and assigned to no one, successors starting after predecessors, committed work inside the
freeze horizon keeping both its person and its start day, planned work staying inside capacity minus
reserve, and an out-of-scope person's committed work being left alone on a scoped cycle. It does not
check the `small` flag, which the solver ignores entirely (STAB-10).

`mobile/test/screens_smoke_test.dart` passes 52 cases against the live API: seventeen screens at
desktop, tablet and phone widths, plus one dark-theme case. Two things a reader should know. The
dark-theme case covers three screens, not seventeen. And there are twenty screen classes in
`mobile/lib/screens/` — change detail, More and sign-in are not in the suite at all. `flutter analyze`
is clean. What none of this does is exercise a single interaction: it proves the screens draw, not
that any button works. Nothing in the repository tests the client's behaviour, which is still where
most of this audit's Partial verdicts sit.

## 5 What would need doing next

In the order that buys the most, if someone picked this up tomorrow.

1. **Fix the tenancy hole in `/v1/assignments`.** It is the only unscoped query in `api/`, it is in
   the one surface built to be consumed from outside, it is a documented parameter, and no test
   covers it. Resolve the version through `dbo.plan_versions WHERE id = ? AND workspace_id = ?`,
   404 otherwise, and refuse a version that is not committed — a read-only public API should not
   publish an unapproved proposal. Then add a tenancy assertion to `tests/public_api_test.php`.
   While there, make `calendar.php` check that a supplied `person_id` belongs to the workspace.

2. **Give the five new server-side surfaces a way in.** This is the old first item repeating one
   level out, and it is the largest gap between what the system can do and what anyone can use.
   In rough value order: a "Publish my calendar" control on the person page with a revoke
   (closes VIEW-09's calendar half and INT-04's publish half); a retention panel in Settings
   (ADM-05, and it is the only Must in R1 with a compliance edge); a webhooks panel with subscribe,
   rotate and delivery history (INT-07); and an intake-sources panel (INT-02). All four are client
   work against APIs that are finished and tested. Register `cron_webhooks.php` and
   `cron_retention.php` as actual scheduled tasks while you are there.

3. **Give the notification set a delivery channel.** All seven kinds fire and `notify()` reads
   `notification_prefs`, but in-app is still the only route: `channel` says `digest` or `teams` when
   a user asks for it and nothing sends either. A weekly digest job (NOT-04) is the cheapest thing
   that would make the preference mean something; push (MOB-04) and Teams (INT-06) need a tenant.
   Raise `item_assigned` from `plan.php move_assignment` too — it was named last time and not done.

4. **Make reporting worth opening.** It is the only capability with nothing Done in it. The
   work-type dimension already exists in `vw_estimate_accuracy` and the CSV and just needs to reach
   the screen (EST-07, REP-01); a team and work-type filter and the two reports that live on other
   screens would close most of REP-01 and REP-02; metric definitions now exist as a pattern in
   `adm_metrics.dart` and need extending to Benefits and Overview (REP-04). PDF is the expensive
   part and can wait.

5. **Close the configuration gaps that make real behaviour unreachable.** Approver roles are still
   `require_role('delivery_lead')` and `has_role('admin')` in code (CHG-07, a Must in R1); the
   re-estimate threshold and the small-fill threshold are both enforced and neither has a Settings
   control (EST-09, STAB-10); there is still no team CRUD endpoint at all and the role dropdown
   admits it is not wired (ADM-06). Teach the CP-SAT solver the `small` flag while you are in there,
   so STAB-10 does not quietly stop holding on a solver workspace.

Below that line, in descending value: the requirements tab as an editable, formatted field with an
admin-editable template, which the last build-out did not touch in either half (REQ-03); showing the
weights and normalised inputs the API already sends, so the priority formula can actually be
reproduced from the item (BEN-03); a control for `protected_until`, which the engine honours and no
screen sets or shows (STAB-12); a way to create a development target, without which the pairing code
can only fire on seed data (TEAM-05, SCH-12); the rest of the person profile — working pattern, max
concurrent, focus days, and moving someone between teams (TEAM-02); coverage counted in the planned
window rather than workspace-wide (REQ-02); drawing dependencies on the schedule (PIP-05); enforcing
or at least surfacing the commit cadence (STAB-05); attachments (PIP-09); qualitative benefits
(BEN-02); and PDF export (VIEW-09's other half).

Three things worth saying plainly to whoever picks this up. First, the previous audit's complaint
about Settings → Integrations has been dealt with properly — it reads the table and reports the truth
— so the remaining honesty problem is elsewhere: `docs/API.md` is described in `CLAUDE.md` as the
contract every screen is built against, and it documents none of `v1.php`, `webhooks.php`,
`calendar.php`, `intake.php` or `retention.php`. Five endpoints exist that the contract does not
mention. Second, `dev_login` still takes a user id and issues a token for them with no secret. That
is correct for a local demo and is gated by `dev_login_enabled`, but it is the first thing that must
be provably unreachable before this goes anywhere near a real tenant. Third, the two rows that moved
down this time (EST-09, STAB-10) and the one re-read more strictly (REQ-02) are not regressions in
the code; they are the same rule applied consistently. A policy an administrator cannot reach is no
more usable than an endpoint no screen calls.

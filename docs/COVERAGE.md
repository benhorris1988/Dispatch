# Coverage audit — Dispatch against requirements v0.1

What this repository actually implements, checked requirement by requirement against
*Dispatch — Requirements and Design v0.1* (`docs/requirements-v0.1.md`, 8 September 2026).

Re-audited 15 September 2026 against the working tree after the organisation-chart release, with the
API running on `http://localhost:8090` and the demo seeded. It supersedes the audit of `053e649`.
Five requirements are new since that audit — ORG-01 to ORG-05, the organisation tree, reporting
lines, role families and who may reorganise what — and three existing rows moved: ADM-01 from Partial
to Done for Google sign-in, ADM-02 and ADM-06 for roles that can now actually be assigned. No row is
Not done. Every verdict
below comes from reading the code that does the work — and, where the requirement implies a person
does something, from finding the control in `mobile/lib/screens/` that reaches it. An endpoint no
screen calls is recorded as such. Schema columns that nothing reads are recorded as such. The status
column is deliberately unkind.

## 1 Summary

| Scope | Done | Partial | Not done | Not applicable here | Total |
|---|---|---|---|---|---|
| All functional requirements | 85 | 41 | 0 | 6 | 132 |
| R1 (the MVP) | 68 | 12 | 0 | 0 | 80 |
| Must priority | 66 | 19 | 0 | 1 | 86 |
| Must **and** R1 | 65 | 11 | 0 | 0 | 76 |
| Should priority | 16 | 22 | 0 | 4 | 42 |
| Could priority | 3 | 0 | 0 | 1 | 4 |

The five ORG requirements are new in this release and did not exist in v0.1; ADM-01 counts as Done
with the client ids left to configure, which the row explains.

**Changed in this release.** ADM-07 moves Partial → Done (campaigns: sandbox workspaces, section 2.14).
TEAM-02 and TEAM-06 move Partial → Done and TEAM-07 moves N/A → Partial, all from the supply-side work
in section 2.12b — a working-pattern editor, a public-holiday calendar, leave balances and a way to
correct an imported availability record. Three capabilities in sections 2.12b, 2.13 and 2.14 are beyond
v0.1 and have no requirement id to sit under, so they are written up as their own sections rather than
counted in this table.

Non-functional: of the 18 NFRs, two are structurally met, eight are partly met, and eight are
hosting or operations claims that a local implementation cannot make. Section 3 sets them out.
One of them has **regressed** since the last audit.

**How complete is this, plainly.** The gap the previous audit led with has largely closed. Its
single biggest complaint was that the API implemented a requirement completely and no screen called
it; eleven rows have since moved from Partial to Done for exactly that reason. Dependencies can now
be added and removed, plan versions viewed and restored, scenarios composed and adopted, the
incident rota assigned, day rates added and versioned, bulk actions run, the schedule grouped,
the benefits register filtered, objective weights edited, and tags and `earliest_start` set on the
add form. Of about 115 API actions, 19 are still never referenced by the client, and most of those are
legitimately server-side jobs. Sixty-six of the eighty R1 requirements are Done, none of the 132 is Not
done, and the eight that once were — role families and loans, multi-team planning, qualitative
benefits, external record links, the weekly digest and the three native-app rows — are now Done or
Partial with the remaining gap named (an iOS build needs a Mac; push and e-mail need credentials).

This release adds the organisation itself. Teams nest under teams, people have a reporting line and a
discipline, and both are edited by dragging them on a chart rather than by an administrator retyping
them — with the authority to do so following the tree rather than a flat role. Portfolios, which
grouped whole teams, became role families, which group people across teams, because the first could
not say that two people in different teams do the same job. Sign-in changed underneath all of it:
the development picker that took a bare user id with no credential is gone, and Google is the way in.

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

The security defect the previous audit led with — `/v1/assignments` filtering on a caller-supplied
`plan_version_id` with no workspace predicate, and serving unapproved proposals — was fixed in
`8343060`: the version is checked for ownership and for committed/superseded status, the rows are
scoped to the workspace as well, and `tests/public_api_test.php` now asserts both.

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
— there is no mail transport or Teams sender anywhere in the repository — push now has a device registry, a queue and a sender that only lack credentials — so
`channel` records the route a user chose rather than one anything acted on. Settings → Integrations
is no longer misleading: it reads `dbo.integrations` and reports all seven connectors as not
connected, which is true. The native apps now exist as platform projects and an Android release APK builds here; the
iOS app is configured but unbuilt for want of a Mac, push is plumbed as far as credentials allow,
and biometric unlock is real (MOB-01/04/05).

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
| REQ-05 | Link to external records by URL with a live status badge | Could | R3 | Done | Was Partial (server only). `work_items.php` now has `set_external_link` / `clear_external_link` (team_lead+, audited as field `external_link`, URL validated as absolute http(s)) and `get` returns `external_link:{url, ref, system, badge}` with `system` inferred from the host (atlassian.net → jira, service-now.com → servicenow, sharepoint.com → sharepoint, dev.azure.com → azure_devops, else other). **The badge is live only where a status genuinely exists**: for an item `intake.php` raised from a ticket system it reads Dispatch's own `intake_log` — `raised` / `duplicate_seen`, `last_seen_at`, `times_seen` — and says in its `note` that this is the caller's posting record, not the ticket's state in the source system. For every other link it is `link_only` with "No integration for <System> is connected; this is a link." There is no Jira, ServiceNow or SharePoint integration, so no badge is ever live *from them*, and none is fabricated. `system` has no column and is re-inferred on read. Asserted in `tests/work_items_test.php` including an intake-raised item. Client: the work item screen has an **External record** panel (`mobile/lib/screens/parts/external_link_panel.dart`) showing the system label, the ref, an Open button (`url_launcher`) and the badge exactly as served — `live: true` states as a coloured chip (raised → ok, duplicate_seen → warn) with "seen N times · last <date>" and the server's note; `link_only` as a neutral "Jira link" chip plus "No integration for Jira is connected; this is a link." No status is ever invented client-side. Team lead+ get Link / Edit / Remove (URL + optional ref; the system is inferred server-side and shown after save; remove is confirmed and audited). Rendered at desktop, tablet and phone by `test/screens_smoke_test.dart` (WI-1042). |

### 2.4 Team, skills and availability (TEAM)

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| TEAM-01 | Skills catalogue; merge and retire | Must | R1 | Done | `skills.php` `save` / `merge` / `retire`; Team & skills → Skills tab wires all three to per-row actions gated on the admin role |
| TEAM-02 | Person profile: role, team, days per week, pattern, max concurrent, min focus, preferences, avoid | Must | R1 | Done | Was Partial: the server took the whole profile and the client could not send it. `parts/tm_pattern_dialog.dart` now edits the working pattern itself — hours per weekday, Monday to Sunday, with presets and a live days-per-week figure — from the person page, alongside the annual-leave entitlement. Max concurrent and focus blocks are still read-only rows, which is a deliberate line: they are scheduling policy per person, and the pattern was the one that made a part-timer's data wrong |
| TEAM-03 | Proficiency 0–4, lead endorsement, certifications attached | Must | R1 | Partial | Levels and endorsement are real and reachable from both the person page and the matrix cell picker. **Certification is a single BIT with no issuer, expiry or file; `set_skill` accepts a `certified` flag that no Dart file sends, and there is no attachment table anywhere** |
| TEAM-04 | Skills matrix with proficiency, people at L3+, demand over the horizon, gaps highlighted | Must | R1 | Done | `skills.php matrix` returns cells, `people_at_3_plus`, a single-point summary and `demand_vs_supply`; rendered as the matrix, summary strip and demand panel with single points flagged and over-demand reddened |
| TEAM-05 | Development targets; scheduler prefers pairing that person as a second | Should | R2 | Partial | The scheduler half is implemented (`pl_try_pairing()`) and the pairing switch is now live and writes. **But the switch can only re-send a target that already exists** — no control creates one, and the panel's own empty state says "Set a target level on a person to plan pairing" with nothing that does so, so targets exist only in seed data |
| TEAM-06 | Availability covers leave, training, rota and recurring patterns | Must | R1 | Done | Was Partial for the recurring half. The recurring element people actually have is the working pattern, which is now editable (TEAM-02), and the recurring absence everybody shares is the public-holiday calendar, which is new: `dbo.public_holidays`, read by `derive_capacity()` so it applies to everyone including later joiners, with the UK dates computed from the rules rather than typed in. Leave, training, sickness and rota all still reduce capacity. What is still absent is a per-person repeating rule ("every other Friday"), which nothing in the demo needs |
| TEAM-07 | Leave imported from HR and calendar, source-marked, correctable but not deletable | Should | R2 | Partial | Was N/A with the note that the local half was "not deletable, not correctable". The correctable half now exists: `people.php update_availability` corrects a record of any source and re-derives capacity over both the old window and the new one, reachable from the person page, while `delete_availability` still refuses anything but `manual`. **The importer itself still needs an HR system and an M365 tenant**, so the row stays Partial rather than Done |
| TEAM-08 | Incident rota per week; that person's reserve rises to the rota percentage | Must | R1 | Done | Was Partial. `screens/parts/adm_rota_panel.dart` lists eight weeks, offers assign per week and a per-person clear, and posts `set_rota` / `clear_rota`; wired into the Availability tab gated on the team-lead role. `capacity.php` applies `rota_reserve_pct` on those weeks, asserted by the engine suite |
| TEAM-09 | People grouped into role families; a person loanable to another team for a dated period | Should | R3 | Done | Reshaped. `dbo.portfolios` is now `dbo.role_families` and the grouping moved from the team to the person (`people.role_family_id`): a role family is the discipline somebody practises, so it spans the tree — *Data engineering* reaches into three of the demo's teams — which a grouping of whole teams could never say. `role_families.php` `list` / `overview` (the family's people grouped by the team each sits in, each row with headcount, loans, share-weighted load, single-skill dependencies, stability index and open proposals, and the family computed the same way as a row rather than summed, which `tests/role_family_test.php` checks to 0.05 of an hour) and admin `save` / `delete` (409 while anybody is in it) / `set_person`. Loans are unchanged and still the time-boxed half of the requirement: `people.php` `add_loan` (overlap → 409, `to_date < from_date` → 400, team-lead-of-either-team or above), `end_loan` (shortens, never deletes; cancels an unstarted loan), `loans`; `list{team_id\|role_family_id}` returns the planning pool with `loaned_from` / `on_loan_to`, `capacity{team_id}` carries `team_share`; capacity is attributed at read time (`capacity.php team_pool` / `team_share_for`), never as a team column on `capacity_days`. A loan moves somebody between teams and never between disciplines, so a family's `loaned_in` / `loaned_out` are always zero and nobody is counted twice. Every mutation audited and raises a `leave` trigger (urgent inside the freeze horizon). Seeded: three role families across five teams, Mei Chen lent to Data Platform 14–25 Sep at 50%. Asserted by `tests/role_family_test.php` (72 checks) and the TEAM-09 section of `engine_test.php`. Client: Team & skills has a scope selector (workspace / role family / team, teams indented by depth) feeding `skills.php matrix` and `people.php list`; borrowed people carry an *On loan from … · until … · 50%* chip and lent-out members *Lent to … until …*; team leads get **Add loan** and **End early** / **Cancel** in the Loans panel. `/role-families/:id` (`RoleFamilyScreen`) renders the overview as a card per team the family reaches into, with the totals row beneath and an admin rename. Person screen has a Loans panel; the Schedule shows the loan chip on the person lane. Rendered at 1440 / 900 / 390 by `screens_smoke_test.dart` |
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
| BEN-02 | Non-financial benefits on a qualitative scale with an optional proxy value, still influencing priority | Should | R2 | Done | Was Partial (server only). `benefits.php save` accepts `is_financial` (default true), a 1–5 `qualitative_scale` (labels minor · useful · significant · major · transformational published by `list.qualitative_scales`) and an optional `proxy_value`; a non-financial benefit must carry a scale (422 otherwise) and may have `annual_value` 0. `engine/priority.php` counts it in the Value term — `proxy_value × confidence` when given, else `scale × priority_weights.qualitativeValuePerPoint` (default 25000) — and records the working in `priority_terms.value` (`financial`, `qualitative`, `proxy_used`, `qualitative_source`). Register money totals stay financial-only; `non_financial_count` and `qualitative_proxy_total` sit alongside, and `export_csv` carries the new columns. Asserted end to end in `tests/benefits_qualitative_test.php` (score rises without a proxy, rises again with one, financial totals unchanged). Client: the register's money tiles stay financial-only and gain "+ N non-financial (≈ £Xk proxy)" plus a "Non-financial benefits" tile with the proxy total marked "priority only"; each non-financial row shows the server's scale label chip (from `list.qualitative_scales`, never hardcoded) with "≈ £50k proxy" instead of a money figure (`mobile/lib/widgets/benefit_widgets.dart`). The shared add/edit form (`mobile/lib/screens/parts/benefit_form_dialog.dart`, used by the register and the work item screen) has a Financial / Non-financial toggle; non-financial reveals the scale picker and optional proxy field and drops the annual value; the 422 message is shown verbatim. The work item's benefit panel gets the same treatment and its priority breakdown's Value term shows the working from `priority_terms.value` — "Financial £147k · qualitative ≈ £35k (proxy)" (or "scale × £25k per point"). Rendered at three widths by `test/screens_smoke_test.dart`. |
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
| SCH-13 | Multi-team scheduling across a branch of the organisation | Could | R3 | Done | `build_model($conn,$wsId,['team_id'\|'role_family_id'])` builds a model of a team and every team beneath it, or of one discipline's people: the pool is the scope's home members plus anyone loaned in, every capacity entry carries the scope's `share` of that day, other teams' committed work is `external` (locked and passed through, so the candidate stays a complete workspace plan). `engine_test.php` proves an item needing Terraform L3 (Data Platform only) and API integration L4 (Integration Platform only) is a skills gap for either team alone and is placed across both by a model of the team above them, with no hard constraint broken. Client: a *Plan · Whole workspace / role family / team* scope picker sits beside **Run the preview** on the Scenarios screen (sends `team_id` / `role_family_id` to `replan.php preview`, which now echoes the scope back; the result panel says *Planned for the … team*), beside **Propose a replan** on the Changes empty state (`propose`; the snackbar names the scope), and the Schedule's propose sends `team_id` when its team filter is on. Limitation: a multi-skill item is only split across teams when its effort is split by skill (`skill_requirements.effort_days` or an estimate `skill_split`) |
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
| CHG-07 | Approval roles configurable: who approves inside the horizon, who overrides guardrails, whether auto-apply is allowed outside it | Must | R1 | Partial | The approval rules are enforced but hardcoded: `require_role('delivery_lead')` to approve and `has_role('admin')` to override, **neither configurable — `workspace_config.php` has no approver-role action and `scheduling_policies` has no approver column**. A second approval path now exists alongside it and is equally hardcoded: a resource request is decided by the requested person's lead chain (section 2.13). The auto-apply clause is done: `auto_apply_outside_horizon` is read by the nightly run, which accepts and commits every pending change that passes all guardrails and falls wholly outside the freeze horizon, audits each, and re-proposes the rest |
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
| NOT-04 | Weekly digest of next week's plan and changes since the last one | Should | R2 | Partial | Was Partial (server only). `digest.php compose_digest()` builds, per user, next week's committed assignments for their person (clipped to the week, with effort against capacity), changes affecting them since `users.last_digest_at` (from `person_change_log` and committed `change_proposals`), changes awaiting their acknowledgement, watch-list entries naming them and the notifications their own preferences routed to the `digest` channel — the stored preference is now consumed — with plain-text and HTML renderings. `preview` (own, any role; `user_id` for team_lead+) and `send` (admin; everyone with `email_digest` on when no id) exist, plus `cron_digest.php` documented for Task Scheduler. **There is still no mail transport in this repository**: `engine/mail_lib.php` will use an `smtp` block or PHP `mail()` from `api/config.php` when one is set, and otherwise writes the digest to `dbo.notifications` as kind `digest` and reports `{sent:false, in_app:true, reason:'no mail transport configured'}` — it never claims to have emailed. `last_digest_at` advances only when something was delivered. Asserted in `tests/policy_notifications_test.php` (composition, in-app landing, `last_digest_at`, undelivered when in-app is off). Client: the notifications page has a **Weekly digest** button that calls `digest.php preview` and renders the structured sections as panels (`mobile/lib/screens/parts/digest_view.dart`) — next week's committed assignments with effort against capacity, changes since the last digest, awaiting acknowledgement, watch-list mentions, digest-routed notifications — not the HTML blob. The footer states delivery from the response: the server's `delivery_note` verbatim when present ("No mail transport is configured … would land … as an in-app notification of kind digest, not as an email"), else "Delivered by email (<transport>)", else "Delivered in-app". The preferences editor already exposes `email_digest` and the `digest` cadence per kind; admins get "Send now" with the `send` response's recipients / emailed / in-app / undelivered counts and note shown verbatim. The `digest` notification kind has its own icon. **Still open: `cron_digest.php` is not registered as a scheduled task, and there is no mail transport in this repository** |
| NOT-05 | Comments on items and proposals support @mentions and link to the exact change | Should | R2 | Partial | @mentions are parsed on **work-item** comments only and link to the item, not to a change. **Change-proposal comments do no mention parsing** — they notify everyone affected under kind `change_proposed` — **and `mention` is still absent from `NOTIFICATION_KINDS`**, so such notifications appear in nobody's preference list and honour no per-kind setting |

### 2.12 Reporting and analytics (REP)

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| REP-01 | Seven reports | Must | R2 | Partial | Five are there: stability trend, load planned against actual, estimate accuracy, delivered by type per month, and cycle time. Benefit realisation by quarter and skills demand against supply exist but on the Benefits and Team screens, not in Reports. **Accuracy still groups only by size on screen**, though `vw_estimate_accuracy` and the CSV now carry a work type |
| REP-02 | Filter by team, period and work type; export to CSV and PDF; schedule by email | Should | R2 | Partial | Period only (4w / 12w / 12m). **No team or work-type filter, no PDF, and the "Schedule email" dialog is still an admitted stub** — "Scheduled email is not wired up in this build." Worth knowing: Export is not a download either — `showTmCsvDialog` shows the CSV in a selectable text box with a copy button |
| REP-03 | Read-only analytics dataset for Power BI with row-level security matching app permissions | Should | R3 | Partial | Two views exist, `vw_assignments_committed` and `vw_estimate_accuracy`. **No row-level security of any kind — no security policy, no predicate function, no `SESSION_CONTEXT` — and no benefits or stability view.** `/v1` is a workspace-scoped read-only surface Power BI could consume instead, but it carries the caller's role rather than row-level security |
| REP-04 | Every metric has an in-app definition | Must | R2 | Partial | Much improved: `mobile/lib/widgets/adm_metrics.dart` carries eleven definitions with formula, inclusions and exclusions, surfaced through `TmMetricTitle` on Team & skills, Person and the Settings day rates, on top of the four `reports.php` returns. **Remaining gap: the Benefits screen and every stat tile on Overview and the Pipeline still carry no definition** |

### 2.12a Organisation (ORG)

New in this release. The requirements are new too (§6.4 of the requirements document): v0.1 had a flat
list of teams, a portfolio above them and a free-text `line_manager`, and said nothing about hierarchy,
reporting lines or who may reorganise what.

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| ORG-01 | Teams nest under teams; a team's planning scope is that team and everything beneath it | Should | R3 | Done | `teams.parent_team_id` with `sort_order`, `description`, `directory_object_id`, `visibility` and `visibility_reason`. `engine/org_lib.php team_closure()` reads the whole tree once per request and every ancestor/descendant question comes out of that array rather than a recursive query each time; every walk is cycle-safe, because the API prevents cycles and the schema cannot. `scope_team_ids()` makes `team_id` mean the subtree, so `people.php list`, `skills.php matrix`, `plan.php`, `build_model()` and `replan.php` all inherit it — `engine_test.php` proves a parent team's model carries the 8 home members of its whole sub-tree and a leaf team's just its own 3, and `role_family_test.php` that `people.php list{team_id}` does the same |
| ORG-02 | Reporting line and role family per person, neither free text | Should | R3 | Done | `people.manager_person_id` (FK, validated against self-management and loops) and `people.role_family_id` (FK). The old free-text `line_manager` column is kept and never written again: the API returns the manager's name derived from the key, so anything that read it keeps working. Set from the organisation chart (`org.php set_manager`, and the details panel's dropdown), from `people.php save`, and per person by an administrator through `role_families.php set_person` |
| ORG-03 | Drag to reorganise; a person's move is confirmed, audited and blocked by a loan | Should | R3 | Done | `org.php` `move_team` (409 for a cycle, siblings renumbered at both ends) and `move_person`, which shares `move_person_home_team()` with `people.php save` so a drag on the chart and an edit in the person dialog obey the same rules and write the same audit entry. A loan is a statement about a home team, so an outstanding one out of the old team or into the new blocks the move with 409 **and the loans named**; `force` then ends a running loan yesterday and deletes one that has not started, both audited. The client confirms first in plain words — committed work stays with them, the load figures change, the loan stays — and on the 409 offers *Move anyway*. Verified end to end in a browser: a long press lifts a card, a short drag still pans the canvas, and the drop redraws the tree and says what happened |
| ORG-04 | Visible to everyone unless restricted for a stated reason | Should | R3 | Done | `set_visibility` refuses to restrict without a reason (422) and clears the reason when the restriction is lifted. `team_visible_to()` returns a stub — the team's name and where it sits, nothing else — to everyone except administrators, the restricting team's lead chain and the people inside that subtree. A delivery lead does **not** bypass it, which `org_test.php` asserts by viewing the same tree as five different people. The chart draws a stub as a dashed card saying *Restricted*, so the shape of the organisation is never a hole |
| ORG-05 | Authority follows the tree | Must | R3 | Done | `require_team_authority()` (modelled on `require_loan_authority`): delivery lead and administrator anywhere, team lead within the team they lead and everything beneath it, both ends checked on any move. `editable_team_ids()` tells the client which teams it may offer controls for, so they are hidden rather than 403'd — the house rule. `org_test.php` covers the refusals from both sides: a lead cannot create, move, restrict or delete in somebody else's branch, and can in their own |

### 2.13 Administration, security and audit (ADM)

| ID | Requirement | Pri | Rel | Status | Evidence, or what is missing |
|---|---|---|---|---|---|
| ADM-01 | Sign-in through the organisation's identity provider; no local passwords | Must | R1 | Done (Google; Entra pending a tenant) | Rewritten. There is no development sign-in any more: `list_dev_users` and `dev_login` are gone, and with them the only path that ever took a bare user id with no credential. Sign-in is **Google**, on web, Android and iOS: `auth.php google_login` verifies the ID token against Google's JWKS through the provider-agnostic `oidc_lib.php` (RS256 only, `alg:none` refused, issuer, audience and expiry checked, `email_verified` required, optional `hosted_domain` enforced), then issues the app's own token. `oidc_lib.php` reads **both** JWK shapes — Entra's `x5c` certificates and Google's bare `n`/`e` moduli, the latter via a hand-built SubjectPublicKeyInfo PEM — which is the difference between a verifier that works and one that silently accepts nothing; `tests/auth_test.php` proves it offline against a generated keypair, including the forgery cases. The client asks `auth.php providers` what to draw, so client ids are configuration rather than build artefacts and one web build serves any deployment; the mobile apps send the web client id as their server client id so every platform's token carries an audience the API accepts. **What is not done here: the Google client ids themselves.** `google.client_ids` in `api/config.php` is empty in this environment, so `providers` reports Google off and the sign-in screen says so and names the file to fix. Entra is kept verified and switched off behind the same `providers` gate. |
| ADM-02 | Seven roles, documented, enforced server-side | Must | R1 | Done | `DP_ROLE_RANK` in `lib.php` with `require_role()` call sites across every endpoint, re-read from the database on every request so a role change applies without re-login, and documented in Settings → Teams and roles. Verified live: a team-member token is refused retention, webhook and deactivate actions with 403. **Roles are now assignable in the product**: `auth.php set_role` (admin; 400 for an unknown role, 409 when the only administrator would demote themselves out of the workspace, audited with the reason) behind a live dropdown in Settings → Teams & roles, which is hidden rather than disabled for anyone who may not use it. `auth.php list_users` is team-lead-and-above: who is in the workspace and what role they hold is not a secret, changing it is. ORG-05 adds a second, hierarchical layer of authority over the organisation tree on top of the flat rank. |
| ADM-03 | Users provisioned from the directory; leavers deactivated automatically with future assignments flagged | Should | R2 | Partial | The client gap is closed: `person_screen.dart` `_deactivate()` calls `people.php deactivate` behind a confirmation stating how many future assignments are affected, and the control is omitted rather than 403'd for non-admins. The server notes every future assignment as needing reassignment and raises an urgent trigger. Provisioning is now just-in-time: an account is created the first time somebody signs in with an accepted identity, as an administrator when their address is listed in `bootstrap_admins` and a team member otherwise, linked to the `people` row with the same work address if there is one. A deactivated account is refused rather than re-created, which is what deactivating a leaver is for. **What is still absent: the directory half** — no SCIM endpoint and no group-sync job, so deactivation is admin-initiated rather than automatic, and `teams.directory_object_id` is the column an Entra group sync will write to and nothing reads yet |
| ADM-04 | Every create, update, delete, approval and configuration change audited; searchable and exportable | Must | R1 | Done | `audit()` records actor, time, entity, label, before and after JSON and reason from about eighty-four call sites including config changes, approvals and commits; `audit.php` gives entity, action, actor, free-text and date filters, paging and CSV, exposed in Settings. The export lands in a clipboard dialog rather than a downloaded file |
| ADM-05 | Personal data minimised; leave reasons never stored; retention policy removes plan history after a configurable period | Must | R1 | Partial | Was Partial for a different reason — the retention half now exists. Data minimisation is still honoured deliberately: `availability` holds a type and nothing else and `add_availability` drops any reason. `api/retention.php` adds `get` / `save` / `preview` / `purge` over new `workspaces.plan_history_months` (24) and `audit_retention_years` (7) columns; the scan protects the committed version, the newest superseded one and anything a proposal references, and the purge writes its audit row before trimming the audit table. `cron_retention.php` is the job. **But `grep` for retention across `mobile/lib/` returns nothing**, so no administrator can see the period, change it, preview a purge or run one from the app. `intake_log.payload` and `notifications` are covered by no retention rule at all |
| ADM-06 | Administrators manage day rates, skills catalogue, teams, integrations and notification defaults | Must | R1 | Partial | Day rates are now genuinely editable (see EST-05), and skills, work types, size classes and policy all save. Two of the three gaps are closed: `org.php` is the team CRUD that existed nowhere — `save_team` / `move_team` / `delete_team` / `set_visibility`, reachable by drag on the Organisation chart and by menu in its list view — and the role dropdown in Teams & roles is live against `auth.php set_role`. **What remains: integrations are read-only, and the "notification defaults" table is `notifications.php prefs` scoped to the signed-in user, so it shows an administrator their own preferences rather than editable workspace defaults** |
| ADM-07 | Multiple workspaces in one tenancy, a user able to belong to more than one | Should | R3 | Done | Was Partial. The tenancy model was always sound — every table carries `workspace_id` and every query filters on it — and what was missing was a way to make a second workspace, get into it and know which one you are in. `campaigns.php` does all three: `create` (a full copy, a config-only copy, or the demo dataset), `switch` (which **re-issues** the token rather than widening it), `reset`, `delete`. A user now has one `users` row per workspace keyed on their email, so a role, a linked person and notification preferences stay per workspace. `tests/campaigns_test.php` proves the isolation both ways: a change in a campaign leaves Live untouched, and neither token can read the other's rows. **Sign-in still always lands in Live** (ADM-01), which is deliberate: an account exists because somebody signed in with an identity the deployment accepts, and no sandbox can mint one |

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
| MOB-01 | Native iOS and Android apps with parity for My week, item, proposals, add work, notifications and self-service | Must | R2 | Partial | Was Not done. The Flutter codebase now has native platform projects: `mobile/android/` (application id `uk.co.dispatch.app`, label Dispatch, `minSdk = 30` for Android 11, INTERNET permission, a network security config that allows plain http only to the emulator's host alias, and a launcher plus adaptive icon rendered from the design's orange mark) and `mobile/ios/` (bundle id `uk.co.dispatch.app`, deployment target 16.0, the full icon set). **A release APK builds on this machine**: `flutter build apk --release --dart-define=API_BASE=http://10.0.2.2:8090/api` → `mobile/build/app/outputs/flutter-apk/app-release.apk`, 57.4 MB for all ABIs (`aapt dump badging` confirms the package, `sdkVersion 30` and the label), and every screen still renders at phone width (`screens_smoke_test.dart`, 52 tests). Parity with the list in the requirement comes from the same routes rendering at every width. **Not Done because the iOS app has not been built — there is no macOS or Xcode here — so the iOS project is configured but unproven, and the APK is signed with the debug key (MOB-07)** |
| MOB-02 | Schedule read-only on tablets, simplified per person on phones | Should | R2 | Done | Was Partial. Both halves are implemented: `canPlan && Breaks.isDesktop(context)` is passed into the grid, so at tablet width the lane view renders with no draggable blocks, and `_phoneBody` replaces lanes with a group control, a lane dropdown, a summary and a per-week block list including away days. One caveat: the page-level "Propose replan" button is not width-gated, so the lane view is read-only on a tablet but the page is not quite |
| MOB-03 | Offline reading of My week, items and proposals; actions queued and confirmed on reconnect | Should | R2 | Partial | `services/my_week_cache.dart` caches the last My week payload per person and week with a staleness banner, actions disabled while offline and a clear on sign-out. **Items and proposals are not cached and there is no offline action queue at all** — nothing replays a mutation on reconnect |
| MOB-04 | Push through APNs and FCM with deep links | Must | R2 | Partial | Was Not done. Deep links are complete: `dispatch://items/WI-1042`, `dispatch://changes/12`, `dispatch://my-week` and https App Links / Universal Links to the hosted web build (`/mobile/build/web/#/…`) are declared in the Android manifest and `Info.plist`, mapped by `services/deep_links.dart`, rewritten in the go_router redirect and carried through sign-in via `from`; a tapped notification's `link` follows the same path (`test/deep_links_test.dart`). The server side is complete: `devices.php` (register with upsert on token, unregister, list, test_push, deliveries — audited and tenanted), `engine/push_lib.php` (`notify()` queues one `push_deliveries` row per active device; `push_dispatch()` sends via FCM HTTP v1 with a service-account OAuth token or APNs with an ES256 provider token, deactivates dead tokens, backs off 1m/5m/30m) and `cron_push.php`, covered by `tests/devices_test.php` (63 checks). **What is missing is a push SDK in the client and provider credentials on the server.** `PushService.instance` is a `NoopPushService`: a Firebase project's `google-services.json` / `GoogleService-Info.plist` is a credential and was not faked, so no device ever registers; and with no `push.*` keys in `config.php` every queued delivery is marked `unconfigured` with the missing key named — never `sent`. `mobile/README.md` lists the two files and the one class a real project drops in |
| MOB-05 | Biometric unlock; sessions follow conditional access | Must | R2 | Partial | Was Not done. Biometric unlock is implemented with `local_auth` (`services/app_lock.dart`, `screens/lock_screen.dart`): offered once after an interactive sign-in on a capable device and, when on, a full-screen lock view — not a dialog — covers the app on cold start and on returning from the background after a configurable idle period (Immediately / 1 / 5 / 15 / 30 minutes, default 5), with "Use PIN/passcode instead" through the OS device-credential fallback, failures explained in place, and a switch, idle picker and "Lock now" under More → Security. The preference lives in `shared_preferences` on the device; the API token is untouched; web and desktop never see the option. `test/deep_links_test.dart` drives it through a fake gate (19 tests). **Conditional access is not done and cannot be exercised here**: it is a property of the identity provider's own policy, and neither a Google account in this environment nor the minted token the tests use has one to follow |
| MOB-06 | Platform conventions respected while keeping one visual identity | Must | R2 | Partial | Material 3, light and dark themes, bottom tabs on phone and one visual identity throughout. **Browser conventions, not platform ones: no back-gesture handling, no share sheet, no dynamic type** |
| MOB-07 | Distributed through Intune and the public stores | Must | R2 | N/A | Needs an Intune tenant and store accounts, and there is no signing configuration or store metadata either. In its place: `flutter build web --release` served from a URL |

### 2.12b The supply side: public holidays, patterns and leave balances (new)

TEAM-02, TEAM-06 and TEAM-07 were all recorded Partial for the same underlying reason: the data
existed and nothing could reach or complete it. This closes that.

| Capability | Status | Evidence |
|---|---|---|
| Public holidays reduce capacity | Done | `dbo.public_holidays` + `holiday_map()`; `derive_capacity()` writes 0/0 on a holiday, so it applies to everyone including later joiners, and nothing is stored against a person. `holidays.php import_uk` computes a year from the rules (`api/holidays_rules.php`) with no network call and no list to maintain — the seed uses the same function |
| A working pattern can be edited in the client (TEAM-02) | Done | Was Partial: the edit dialog covered six fields and the pattern was a read-only row. `parts/tm_pattern_dialog.dart` edits all seven weekdays with presets, re-derives days per week, and the person page shows the entitlement beside it |
| Weekend working | Done | `effective_working_days()` widens the day grid by any weekday a pattern gives hours to, in `derive_capacity()` and in the model's grid, so a Saturday worker's Saturdays carry real capacity instead of vanishing |
| An availability record can be corrected (TEAM-07) | Done | Was N/A with the note "not deletable, not correctable". `people.php update_availability` corrects any source and re-derives both windows; `delete_availability` still refuses anything but `manual`. Both reachable from the person page |
| Leave entitlement and balance | Done | `leave_balance()` counts booked leave in the person's own days — a Mon–Thu worker booking a week spends four, and a bank holiday inside a booking costs nobody anything. Shown on the person page with the copy saying it is for planning, not an HR record |
| One implementation of "hours on a day" | Done | `day_hours()`. There were five, and two disagreed about overlapping leave (added-and-clamped when derived, multiplied in the model fallback). `capacity.php`, `model.php`, `watchlist.php` and `plan.php` now all call it |
| Per-person hours where the workspace day was assumed | Done | `plan.php` lane headers counted weekdays × 7.5 (a part-timer read as over-loaded); `digest.php` counted weekdays (a Mon–Thu worker was told they had five days every week). Both now read the derived capacity |
| Leave approval workflow | N/A | Out of scope by the requirements themselves (section 3 excludes being the system of record for leave approval). The balance is informational and says so |
| Importing leave from HR (TEAM-07's first half) | Not done | There is still no importer. What changed is that an imported row can now be corrected once it is there |

### 2.13 Resource requests and approval (new, beyond v0.1)

Not in the requirements document. The gap it closes is real, though, and the document is close to
naming it: CHG-07 asks for configurable approval, and the roles table gives a requester nothing to
do after raising a work item. Until now the only way a named person got booked was the engine
proposing it or a delivery lead dragging a block — a project owner could not ask for somebody, and
the lead who actually manages that person had no say at all.

| Capability | Status | Evidence |
|---|---|---|
| A requester asks for a named person for an amount of time on a work item | Done | `resource_requests.php create`, reached from the Requests panel on the work item screen (`Request a person`). A team lead may ask on anything; below that only on work you raised or own |
| Hours become dates against that person's own capacity | Done | `requests_lib.php request_span()` reads `capacity_days`, skips days with no schedulable time and derives the allocation from the day set, so 7.5 hours from a Friday for a half-day-Friday worker books Friday and Monday at 76%, not two whole days. Asserted in `tests/resource_requests_test.php` |
| A lead above that person approves, and one approval is enough | Done | `can_approve_request()` is ORG-05 applied to a person: `team_lead_chain()` of their team, or a delivery lead. The suite proves a lead of a sibling branch gets 403 naming who can decide, and that both the immediate lead and the lead above them can |
| Approving books them into the committed plan | Done | `approve_request()` writes a new committed version through `new_committed_version()` with `fixed_person`/`fixed_dates` set, an already-decided manual proposal and its accepted change, `person_change_log`, the stability week and a batched replan trigger. The engine reproduces a fixed booking rather than planning it away |
| Inside the freeze horizon a reason is required | Done | Same rule and message shape as `changes.php decide` and `plan.php move_assignment`; 409 with `reason_required`, and the client re-asks with the server's sentence |
| Everyone who should hear about it, does | Done | `approval_requested` to the lead chain and the delivery leads, `item_assigned` to the person booked, `request_decided` to whoever asked — on approval, decline and expiry |
| A request nobody decides is closed off | Done | `expire_requests()` in `replan.php run_nightly` (`steps.requests_expired`), asserted in `tests/engine_test.php` because `create` refuses a past start date |
| Over-booking is reported, not prevented | Deliberate | A committed plan books people at or near 100%, so nearly every request lands on top of something. The preview and the approval response carry `fit` and `over_booked` and the next cycle moves lower-priority work; blocking would mean no request could be approved against a healthy plan |
| Approver roles configurable | Not done | The lead chain is the rule, hardcoded, exactly as CHG-07 records for the rest of the approval model. There is no approver column on `scheduling_policies` and no action to set one |
| Requesting a skill rather than a named person | Not done | v1 is a named person only. The engine already places by skill; asking for "anyone at Terraform L3" would be a different shape of request |

### 2.14 Campaigns: sandbox workspaces (new)

The requirement this answers is ADM-07, which the previous audit scored Partial for a precise
reason: the isolation existed and nothing could use it.

| Capability | Status | Evidence |
|---|---|---|
| Make a second workspace | Done | `campaigns.php create` in three shapes — a full copy (people, pipeline and the committed plan), a config-only copy (everything needed to plan, no work), or the demo dataset. The demo path includes `seed_demo_content.php`, the same file the CLI seed uses, so a campaign's demo is the demo the tests run against |
| Copy correctly | Done | `engine/workspace_clone.php` breaks the five circular references (users.person_id, teams.parent_team_id / lead_person_id, people.manager_person_id / role_family_id, role_families.lead_person_id) with a two-pass insert, and derives capacity rather than copying it. The suite checks the counts match and that every person still sits in a team and the team leads survived |
| Move between them | Done | `switch` re-issues the session token for the target workspace; the client throws away the cached config and badge counts with it. A campaign token is only ever good for a campaign |
| Know which universe you are in | Done | `auth.php me` carries `workspace.kind`, and `shell/campaign_banner.dart` puts an amber strip with a "Back to Live" button on **every** screen on both layouts. The account menu and the phone More page name the current workspace |
| Isolation | Done | Row-level `workspace_id` scoping, unchanged. `tests/campaigns_test.php` renames WI-1042 inside a campaign and proves Live still reads the original, and that each token gets a 404 for the other's row |
| Reset and delete | Done | `reset` empties and rebuilds in place, **keeping the workspace id** so links survive (the accounts inside are rebuilt with it, so the reply hands back a fresh token). `delete` removes everything. Both refuse the live workspace with 409, and are limited to whoever created the campaign or an administrator |
| A sandbox cannot reach anything real | Done | Webhook subscriptions and intake sources are never copied (they carry signing secrets), nor are device registrations, calendar-feed tokens, notifications or the audit trail. The weekly digest and push dispatch skip campaigns; the nightly replan does not, because a sandbox that never re-plans is useless |
| Signing in to a campaign directly | Not done, deliberately | Sign-in always lands in Live (ADM-01) and you switch from there. An account exists because somebody signed in with an identity the deployment accepts; letting a sandbox mint one would undo that |
| A campaign with its own "today" | Not done | `today()` takes no workspace and is read in ~40 places. A campaign follows the same clock as Live |

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
  the last clause is no longer contradicted by ADM-07: a person can belong to several workspaces, one
  `users` row each, and move between them (campaigns).
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

The verification bar in `CLAUDE.md` is real and it passes. `tests/run_all.php` now runs eleven
suites — engine; workspace config, people and skills; work items, estimates and benefits; the
qualitative-benefit path; overview, reports and watch list; the plan, proposals and changes HTTP
smoke; the public API, webhooks and calendar feed; devices and push; data retention and purge;
role families and loans; the organisation chart; sign-in and roles; and the policy switches, notifications and urgent cycle — re-seeding before
and after, and every one ran green for this audit. The Flutter smoke test renders eighteen screens
at three widths plus dark theme, and a release Android APK builds.

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
   a user asks for it. The weekly digest (NOT-04) now exists and composes correctly but lands
   in-app until an `smtp` block is configured; push (MOB-04) has its queue, sender and device
   registry and needs only FCM/APNs credentials plus a Firebase-backed `PushService` in the client;
   Teams (INT-06) needs a tenant. Register `cron_digest.php` and `cron_push.php` as scheduled tasks.
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
or at least surfacing the commit cadence (STAB-05); attachments (PIP-09); and PDF export
(VIEW-09's other half).

Four things worth saying plainly to whoever picks this up. First, the previous audit's complaint
about Settings → Integrations has been dealt with properly — it reads the table and reports the truth
— and the contract gap that followed it has been closed too: `docs/API.md` documents every endpoint in
`api/`, including `resource_requests.php`, `holidays.php` and `campaigns.php`.

Second, **the sentence that used to stand here about `dev_login` was out of date and has gone.** There
is no development sign-in and no `dev_login_enabled` switch; the ADM-01 row has said so since Google
sign-in landed, and this paragraph had not caught up. What is worth watching in its place is
`tests/mint_token.php`, which issues a token from the database with no credential: it is CLI-only and
uses the admin connection, and it must stay that way.

Third, the rows that moved down in earlier audits (EST-09, STAB-10) and the one re-read more strictly
(REQ-02) are not regressions in the code; they are the same rule applied consistently. A policy an
administrator cannot reach is no more usable than an endpoint no screen calls.

Fourth, three of the capabilities in this release — resource requests, the supply-side calendar and
campaigns — answer needs the requirements document either names loosely (CHG-07, ADM-07) or does not
name at all. They are written up as sections 2.12b, 2.13 and 2.14 with the same unkind status column,
including what they deliberately do not do.
